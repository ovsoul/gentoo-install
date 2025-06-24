#!/bin/bash

# Script de instalación automática de Gentoo Linux optimizado para AMD A8-7600B
# Características principales:
# - Soporte para GPU Radeon R7 integrada
# - Kernel precompilado (gentoo-kernel-bin)
# - Sistema de audio PipeWire
# - Entorno KDE Plasma
# - Configuración SSD optimizada
# - Español latinoamericano como idioma predeterminado

set -e

### Configuración del sistema ###
DISK="/dev/sdb"                    # SSD objetivo (¡VERIFICAR ANTES DE EJECUTAR!)
HOSTNAME="gentoo-amd"
USERNAME="oscar"
ROOT_PASSWORD="gentoo123"          # ¡Cambiar después de la instalación!
USER_PASSWORD="oscar123"           # ¡Cambiar después de la instalación!
TIMEZONE="America/Santiago"
KEYMAP="la-latin1"
TOTAL_RAM="14"                     # GB de RAM para optimizar swap

### Particiones ###
EFI_SIZE="512MiB"
SWAP_SIZE="4GiB"                   # 4GB suficiente para 14GB RAM

### Colores para output ###
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

### Funciones auxiliares ###
die() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

### Validaciones iniciales ###
[ $EUID -ne 0 ] && die "Este script debe ejecutarse como root"
[ ! -e "$DISK" ] && die "¡El disco $DISK no existe!"

### Configuración inicial ###
info "Iniciando instalación de Gentoo Linux optimizado para AMD A8-7600B"

### Sincronizar reloj ###
info "Sincronizando reloj del sistema..."
if command -v chronyd >/dev/null; then
    chronyd -q
else
    emerge -q net-misc/chrony && chronyd -q || warn "No se pudo sincronizar el reloj"
fi

### Particionado ###
info "Particionando $DISK (EFI: $EFI_SIZE, SWAP: $SWAP_SIZE)..."
parted -s $DISK mklabel gpt
parted -s $DISK mkpart primary fat32 1MiB $EFI_SIZE
parted -s $DISK set 1 boot on
parted -s $DISK mkpart primary linux-swap $EFI_SIZE $SWAP_SIZE
parted -s $DISK mkpart primary ext4 $SWAP_SIZE 100%

### Formateo ###
info "Formateando particiones..."
mkfs.fat -F32 ${DISK}1 || die "Error al formatear EFI"
mkswap ${DISK}2 || die "Error al crear swap"
mkfs.ext4 -O ^has_journal ${DISK}3 || die "Error al formatear root"

### Montaje ###
info "Montando particiones..."
swapon ${DISK}2 || die "Error al activar swap"
mount ${DISK}3 /mnt/gentoo || die "Error al montar root"
mkdir -p /mnt/gentoo/boot
mount ${DISK}1 /mnt/gentoo/boot || die "Error al montar EFI"

### Descarga stage3 ###
info "Descargando stage3..."
STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
wget "$STAGE3_URL" -O /mnt/gentoo/stage3-latest.tar.xz || die "Error al descargar stage3"
tar xpf /mnt/gentoo/stage3-latest.tar.xz -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner
rm /mnt/gentoo/stage3-latest.tar.xz

### Configuración make.conf ###
info "Configurando make.conf para AMD Kaveri..."
cat > /mnt/gentoo/etc/portage/make.conf << 'EOF'
# Optimizado para AMD A8-7600B (Kaveri)
COMMON_FLAGS="-march=btver2 -O2 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j4"

# USE flags para AMD APU
USE="X elogind plymouth dbus networkmanager pulseaudio alsa"
USE="${USE} vaapi vdpau x264 x265 openh264"
USE="${USE} qt5 qt6 kde plasma wayland"

# Drivers de video
VIDEO_CARDS="radeon amdgpu"

# Configuración Portage
GENTOO_MIRRORS="https://mirror.bytemark.co.uk/gentoo/ https://gentoo.mirrors.ovh.net/gentoo-distfiles/"
EMERGE_DEFAULT_OPTS="--quiet-build=y"
ACCEPT_LICENSE="*"

# Optimización para SSD
FEATURES="parallel-fetch parallel-install"
EOF

### Configuración básica ###
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

### Entorno chroot ###
info "Preparando entorno chroot..."
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

### Script de instalación en chroot ###
info "Generando script chroot..."
cat > /mnt/gentoo/install_chroot.sh << 'CHROOT_EOF'
#!/bin/bash

set -e

### Configuración básica ###
echo "Configurando sistema base..."
eselect profile set default/linux/amd64/17.1/desktop/plasma
emerge-webrsync
emerge --sync --quiet

### Zona horaria ###
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data

### Locales ###
echo "es_CL.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set es_CL.utf8
env-update && source /etc/profile

### Kernel ###
emerge sys-kernel/gentoo-kernel-bin linux-firmware

### Configuración del sistema ###
echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname

### Instalación de KDE ###
emerge kde-plasma/plasma-meta kde-apps/kde-apps-meta

### Configuración de usuarios ###
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,usb,users -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd

### Bootloader ###
emerge sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot
grub-mkconfig -o /boot/grub/grub.cfg

### Limpieza ###
rm /install_chroot.sh
CHROOT_EOF

### Ejecución en chroot ###
chmod +x /mnt/gentoo/install_chroot.sh
chroot /mnt/gentoo /install_chroot.sh

### Finalización ###
info "Desmontando particiones..."
umount -R /mnt/gentoo
info "¡Instalación completada!"
warn "¡Recuerda cambiar las contraseñas por seguridad!"
info "Reinicia con: shutdown -r now"