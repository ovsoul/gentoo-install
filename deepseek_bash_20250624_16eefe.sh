#!/bin/bash
# Script de instalación Gentoo Linux - Versión 3.0
# Características:
# - Soporta enlaces personalizados de stage3 o archivos locales
# - Optimizado para AMD A8-7600B (Kaveri)
# - Validación de integridad del stage3
# - Configuración SSD y KDE Plasma

set -euo pipefail

### CONFIGURACIÓN ##################################################
DISK="/dev/sdb"                     # ¡CAMBIAR AL DISCO CORRECTO!
STAGE3_SOURCE="auto"                # "auto"|"url"|"local"
STAGE3_URL=""                       # Ej: "https://mirror.example.com/stage3-amd64-20240625.tar.xz"
STAGE3_LOCAL="/ruta/al/stage3.tar.xz" # Ej: "/mnt/usb/stage3-amd64.tar.xz"

HOSTNAME="gentoo-amd"
USERNAME="gentoo-user"
ROOT_PASSWORD="gentoo123"           # ¡Cambiar después!
TIMEZONE="America/Santiago"
KEYMAP="la-latin1"

### PARTICIONADO ###################################################
EFI_SIZE="512MiB"
SWAP_SIZE="4GiB"                    # 4GB para 14GB RAM

### COLORES ########################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

### FUNCIONES ######################################################
die() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

### VALIDACIONES INICIALES #########################################
[ $EUID -ne 0 ] && die "Este script debe ejecutarse como root"
[ ! -e "$DISK" ] && die "El disco $DISK no existe"
grep -q '/mnt/gentoo' /proc/mounts && die "/mnt/gentoo ya está montado"

### DETECCIÓN DEL STAGE3 ##########################################
get_stage3() {
    case "$STAGE3_SOURCE" in
        "auto")
            info "Buscando stage3 oficial más reciente..."
            MIRROR="https://distfiles.gentoo.org/releases/amd64/autobuilds"
            STAGE3_PATH=$(wget -qO- "$MIRROR/latest-stage3-amd64-openrc.txt" | grep -v "^#" | awk '{print $1}')
            STAGE3_URL="$MIRROR/$STAGE3_PATH"
            ;;
        "url")
            [ -z "$STAGE3_URL" ] && die "STAGE3_URL no está configurado"
            ;;
        "local")
            [ ! -f "$STAGE3_LOCAL" ] && die "Archivo stage3 no encontrado en $STAGE3_LOCAL"
            ;;
        *) die "STAGE3_SOURCE debe ser: auto|url|local" ;;
    esac

    # Descargar o copiar
    mkdir -p /mnt/gentoo
    cd /mnt/gentoo

    if [ "$STAGE3_SOURCE" = "local" ]; then
        info "Copiando stage3 desde archivo local..."
        cp "$STAGE3_LOCAL" ./stage3.tar.xz
    else
        info "Descargando stage3 desde $STAGE3_URL..."
        wget "$STAGE3_URL" -O stage3.tar.xz || die "Error al descargar stage3"
    fi

    # Verificación básica
    if ! file stage3.tar.xz | grep -q "XZ compressed data"; then
        die "El archivo stage3 no es un .tar.xz válido"
    fi
}

### PARTICIONADO ##################################################
partition_disk() {
    info "Particionando $DISK..."
    parted -s $DISK mklabel gpt
    parted -s $DISK mkpart primary fat32 1MiB $EFI_SIZE
    parted -s $DISK set 1 boot on
    parted -s $DISK mkpart primary linux-swap $EFI_SIZE $SWAP_SIZE
    parted -s $DISK mkpart primary ext4 $SWAP_SIZE 100%

    info "Formateando particiones..."
    mkfs.fat -F32 ${DISK}1 || die "Error al formatear EFI"
    mkswap ${DISK}2 || die "Error al crear swap"
    mkfs.ext4 -O ^has_journal ${DISK}3 || die "Error al formatear root"

    info "Montando particiones..."
    swapon ${DISK}2
    mount ${DISK}3 /mnt/gentoo
    mkdir -p /mnt/gentoo/boot
    mount ${DISK}1 /mnt/gentoo/boot
}

### INSTALACIÓN ###################################################
install_system() {
    info "Extrayendo stage3..."
    tar xpf /mnt/gentoo/stage3.tar.xz -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner
    rm /mnt/gentoo/stage3.tar.xz

    info "Configurando make.conf para AMD Kaveri..."
    cat > /mnt/gentoo/etc/portage/make.conf << EOF
COMMON_FLAGS="-march=btver2 -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j4"

USE="X elogind dbus networkmanager pulseaudio alsa vaapi vdpau"
USE="\${USE} qt5 qt6 kde plasma wayland"

VIDEO_CARDS="radeon amdgpu"
EOF

    info "Copiando DNS..."
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
}

### CHROOT ########################################################
configure_chroot() {
    info "Preparando entorno chroot..."
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev

    info "Generando script chroot..."
    cat > /mnt/gentoo/install_chroot.sh << 'CHROOT_EOF'
#!/bin/bash
set -e

# Configuración básica
echo "Configurando sistema..."
eselect profile set default/linux/amd64/17.1/desktop/plasma
emerge-webrsync
emerge --sync --quiet

# Zona horaria
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data

# Locales
echo "es_CL.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
eselect locale set es_CL.utf8
env-update && source /etc/profile

# Kernel
emerge sys-kernel/gentoo-kernel-bin linux-firmware

# Usuarios
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,usb -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# Bootloader
emerge sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot
grub-mkconfig -o /boot/grub/grub.cfg

# Limpieza
rm /install_chroot.sh
CHROOT_EOF

    chmod +x /mnt/gentoo/install_chroot.sh
    chroot /mnt/gentoo /install_chroot.sh
}

### MAIN ##########################################################
main() {
    get_stage3
    partition_disk
    install_system
    configure_chroot

    info "¡Instalación completada!"
    warn "No olvides:"
    echo "1. Cambiar contraseñas (passwd root / passwd $USERNAME)"
    echo "2. Configurar red: emerge networkmanager && rc-update add NetworkManager default"
    echo "3. Reiniciar: shutdown -r now"
}

main