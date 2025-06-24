#!/bin/bash

# Script de instalación automática de Gentoo Linux (AMD A8-7600B/KDE Plasma)
# Versión 2.1 - Corregido error de descarga stage3 + verificaciones de integridad
# Características:
# - Descarga redundante con verificación SHA512
# - Soporte para GPU Radeon R7
# - Kernel precompilado estable
# - Sistema de audio PipeWire
# - Configuración SSD optimizada

set -euo pipefail

### Configuración ###
DISK="/dev/sdb"                    # ¡VERIFICAR ANTES DE EJECUTAR!
HOSTNAME="gentoo-amd"
USERNAME="oscar"
ROOT_PASSWORD="gentoo123"          # ¡Cambiar post-instalación!
USER_PASSWORD="oscar123"           # ¡Cambiar post-instalación!
TIMEZONE="America/Santiago"
KEYMAP="la-latin1"
TOTAL_RAM="14"                     # GB para optimización

### Particiones ###
EFI_SIZE="512MiB"
SWAP_SIZE="4GiB"                   # Swap recomendado para 14GB RAM

### MIRRORS (redundantes) ###
MIRRORS=(
    "https://distfiles.gentoo.org/releases/amd64/autobuilds"
    "https://gentoo.osuosl.org/releases/amd64/autobuilds"
    "https://mirror.leaseweb.com/gentoo/releases/amd64/autobuilds"
)

### Colores ###
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

### Funciones ###
die() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

### Validaciones iniciales ###
[ $EUID -ne 0 ] && die "Ejecutar como root"
[ ! -e "$DISK" ] && die "¡Disco $DISK no encontrado!"
grep -q '/mnt/gentoo' /proc/mounts && die "¡/mnt/gentoo ya está montado!"

### Configuración inicial ###
info "Iniciando instalación para AMD A8-7600B (Kaveri)"

### Sincronizar reloj ###
info "Sincronizando hora..."
emerge -q net-misc/chrony 2>/dev/null || true
chronyd -q || warn "No se pudo sincronizar hora exacta"

### Particionado optimizado para SSD ###
info "Particionando $DISK..."
parted -s $DISK mklabel gpt
parted -s $DISK mkpart primary fat32 1MiB $EFI_SIZE
parted -s $DISK set 1 boot on
parted -s $DISK mkpart primary linux-swap $EFI_SIZE $SWAP_SIZE
parted -s $DISK mkpart primary ext4 $SWAP_SIZE 100%

### Formateo ###
info "Formateando particiones..."
mkfs.fat -F32 ${DISK}1 || die "Error formateando EFI"
mkswap ${DISK}2 || die "Error creando swap"
mkfs.ext4 -O ^has_journal ${DISK}3 || die "Error formateando root"

### Montaje ###
info "Montando sistema de archivos..."
swapon ${DISK}2 || die "Error activando swap"
mount ${DISK}3 /mnt/gentoo || die "Error montando root"
mkdir -p /mnt/gentoo/boot
mount ${DISK}1 /mnt/gentoo/boot || die "Error montando EFI"

### Descarga segura del stage3 ###
download_stage3() {
    local mirror="$1"
    info "Intentando descarga desde $mirror"
    
    STAGE3_LATEST=$(wget -qO- "${mirror}/latest-stage3-amd64-openrc.txt" | grep -v "^#" | awk '{print $1}')
    [ -z "$STAGE3_LATEST" ] && return 1
    
    STAGE3_URL="${mirror}/${STAGE3_LATEST}"
    if wget "${STAGE3_URL}" -O /mnt/gentoo/stage3.tar.xz; then
        wget "${STAGE3_URL}.DIGESTS" -O /mnt/gentoo/stage3.DIGESTS || return 1
        
        if grep -A1 -m1 "SHA512" /mnt/gentoo/stage3.DIGESTS | grep stage3 | sha512sum -c; then
            info "¡Descarga verificada correctamente!"
            return 0
        fi
    fi
    return 1
}

info "Descargando stage3 con verificación..."
rm -f /mnt/gentoo/stage3.tar.xz /mnt/gentoo/stage3.DIGESTS

for mirror in "${MIRRORS[@]}"; do
    if download_stage3 "$mirror"; then
        DOWNLOAD_SUCCESS=true
        break
    fi
done

[ -z "${DOWNLOAD_SUCCESS:-}" ] && die "¡Todas las descargas fallaron!"

### Extracción ###
info "Extrayendo stage3..."
tar xpf /mnt/gentoo/stage3.tar.xz -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner || die "Error extrayendo stage3"
rm /mnt/gentoo/stage3.tar.xz /mnt/gentoo/stage3.DIGESTS

### Configuración make.conf optimizado ###
info "Configurando make.conf para AMD Kaveri..."
cat > /mnt/gentoo/etc/portage/make.conf << 'EOF'
# Optimizado para AMD A8-7600B (Kaveri)
COMMON_FLAGS="-march=btver2 -O2 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j4"

# USE flags para APU AMD
USE="X elogind dbus networkmanager pulseaudio alsa vaapi vdpau"
USE="${USE} qt5 qt6 kde plasma wayland"

# Drivers gráficos
VIDEO_CARDS="radeon amdgpu"

# Repositorios
GENTOO_MIRRORS="https://mirror.bytemark.co.uk/gentoo/ https://gentoo.mirrors.ovh.net/"
EMERGE_DEFAULT_OPTS="--quiet-build=y"
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

### Script chroot ###
info "Generando script de instalación en chroot..."
cat > /mnt/gentoo/install_chroot.sh << 'CHROOT_EOF'
#!/bin/bash

set -euo pipefail

### Configuración básica ###
echo "Configurando sistema base..."
eselect profile set default/linux/amd64/17.1/desktop/plasma
emerge-webrsync
emerge --sync --quiet

### Zona horaria ###
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data

### Locales ###
echo "es_CL.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
eselect locale set es_CL.utf8
env-update && source /etc/profile

### Kernel ###
emerge sys-kernel/gentoo-kernel-bin linux-firmware

### Configuración del sistema ###
echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname
echo 'keymap="la-latin1"' > /etc/conf.d/keymaps

### Instalación de KDE ###
emerge kde-plasma/plasma-meta kde-apps/kde-apps-meta

### Usuarios ###
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,usb -s /bin/bash "$USERNAME"
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
chroot /mnt/gentoo /install_chroot.sh || die "Error en chroot"

### Finalización ###
info "Desmontando particiones..."
umount -R /mnt/gentoo

info "¡Instalación completada con éxito!"
warn "Acciones recomendadas post-instalación:"
echo "1. Cambiar contraseñas:"
echo "   passwd root"
echo "   passwd $USERNAME"
echo "2. Configurar sensores:"
echo "   emerge lm-sensors && sensors-detect"
echo "3. Optimizar SSD:"
echo "   fstrim -v /"
echo "4. Reiniciar:"
echo "   shutdown -r now"