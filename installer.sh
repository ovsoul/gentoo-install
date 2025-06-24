#!/bin/bash
# Script de instalación Gentoo Linux - Versión 3.3
# Específico para: stage3-amd64-openrc-20250622T165243Z.tar.xz

set -euo pipefail

### CONFIGURACIÓN ##################################################
DISK="/dev/sdb"                                  # ¡CAMBIAR AL DISCO CORRECTO!
STAGE3_PATH="/home/gentoo/Downloads/stage3-amd64-openrc-20250622T165243Z.tar.xz"  # Ruta exacta de tu stage3
HOSTNAME="gentoo-box"
USERNAME="gentoo-user"
ROOT_PASSWORD="gentoo123"                        # ¡Cambiar después!
TIMEZONE="America/Santiago"
KEYMAP="la-latin1"

### HARDWARE AMD A8-7600B #########################################
CPU_FLAGS="-march=btver2 -O2 -pipe"              # Optimización para Kaveri
SWAP_SIZE="8G"                                   # 4GB swap para 14GB RAM
VIDEO_CARDS="radeon amdgpu"                      # Para GPU Radeon R7

### VERIFICACIÓN DE INTEGRIDAD ####################################
STAGE3_SHA512="a79f7d8a7e2e9b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1"  # Reemplaza con tu checksum real

### COLORES ########################################################
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; NC='\033[0m'

### FUNCIONES ######################################################
die() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

### VALIDACIONES INICIALES #########################################
[ $EUID -ne 0 ] && die "Ejecutar como root"
[ ! -e "$DISK" ] && die "Disco $DISK no encontrado"
[ ! -f "$STAGE3_PATH" ] && die "Archivo stage3 no encontrado en:\n$STAGE3_PATH"

### VERIFICACIÓN DEL STAGE3 ########################################
verify_stage3() {
    info "Verificando integridad del stage3..."
    
    # 1. Checksum SHA512
    if [ -n "$STAGE3_SHA512" ]; then
        info "Calculando checksum SHA512 (puede tardar)..."
        echo "$STAGE3_SHA512  $STAGE3_PATH" | sha512sum -c || die "¡Checksum no coincide!\nDescarga el archivo nuevamente."
    fi
    
    # 2. Verificación de formato
    if ! file "$STAGE3_PATH" | grep -q "XZ compressed data"; then
        die "El archivo no es un .tar.xz válido"
    fi
    
    # 3. Tamaño mínimo (100MB)
    local file_size=$(du -m "$STAGE3_PATH" | cut -f1)
    [ "$file_size" -lt 100 ] && die "Archivo demasiado pequeño (¿descarga incompleta?)"
}

### PARTICIONADO PARA SSD ##########################################
partition_disk() {
    info "Creando tabla de particiones GPT..."
    parted -s "$DISK" mklabel gpt
    
    info "Creando particiones:"
    parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" mkpart primary linux-swap 513MiB 4.5GiB
    parted -s "$DISK" mkpart primary ext4 4.5GiB 100%
    
    info "Formateando:"
    mkfs.fat -F32 "${DISK}1" || die "Error al formatear EFI"
    mkswap "${DISK}2" || die "Error al crear swap"
    mkfs.ext4 -O ^has_journal "${DISK}3" || die "Error al formatear root"
    
    info "Montando:"
    swapon "${DISK}2"
    mount "${DISK}3" /mnt/gentoo
    mkdir -p /mnt/gentoo/boot
    mount "${DISK}1" /mnt/gentoo/boot
}

### PREPARACIÓN DEL SISTEMA BASE ##################################
prepare_system() {
    info "Copiando stage3..."
    cp "$STAGE3_PATH" /mnt/gentoo/
    cd /mnt/gentoo
    
    info "Extrayendo (esto puede tardar)..."
    tar xpf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner
    rm -f stage3-*.tar.xz
    
    info "Configurando make.conf para AMD Kaveri:"
    cat > /mnt/gentoo/etc/portage/make.conf << EOF
# Optimizaciones para AMD A8-7600B
COMMON_FLAGS="${CPU_FLAGS}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j4"

# Controladores y características
USE="X elogind dbus networkmanager pulseaudio alsa"
USE="\${USE} vaapi vdpau qt5 qt6 kde plasma"
VIDEO_CARDS="${VIDEO_CARDS}"

# Repositorios
GENTOO_MIRRORS="https://distfiles.gentoo.org https://mirror.leaseweb.com/gentoo"
EOF

    info "Configurando DNS:"
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
}

### CHROOT SETUP ##################################################
setup_chroot() {
    info "Montando sistemas de archivos especiales:"
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    
    info "Creando script chroot..."
    cat > /mnt/gentoo/install_chroot.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail

# Configuración básica
echo "Configurando sistema..."
eselect profile set default/linux/amd64/17.1/desktop/plasma
emerge-webrsync
emerge --sync --quiet

# Zona horaria y locales
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "es_CL.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
eselect locale set es_CL.utf8
env-update && source /etc/profile

# Kernel precompilado
emerge sys-kernel/gentoo-kernel-bin linux-firmware

# Configuración del sistema
echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname
echo 'keymap="la-latin1"' > /etc/conf.d/keymaps

# Usuarios y permisos
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,usb -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# Bootloader (UEFI)
emerge sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot
grub-mkconfig -o /boot/grub/grub.cfg

# Limpieza
rm /install_chroot.sh
CHROOT_EOF

    chmod +x /mnt/gentoo/install_chroot.sh
    info "Ejecutando configuración en chroot..."
    chroot /mnt/gentoo /install_chroot.sh || die "Error en chroot"
}

### POST-INSTALACIÓN ##############################################
post_install() {
    info "Desmontando particiones..."
    umount -R /mnt/gentoo 2>/dev/null || warn "Advertencia: Algunas particiones no se desmontaron limpiamente"
    
    echo -e "\n${GREEN}¡Instalación completada con éxito!${NC}"
    echo -e "\n${YELLOW}Acciones recomendadas después de reiniciar:${NC}"
    echo "1. Cambiar contraseñas:"
    echo "   passwd root"
    echo "   passwd $USERNAME"
    echo "2. Configurar red:"
    echo "   emerge --ask net-misc/networkmanager"
    echo "   rc-update add NetworkManager default"
    echo "3. Instalar software adicional:"
    echo "   emerge --ask kde-apps/konsole kde-apps/dolphin"
    echo -e "\nReinicia con: ${GREEN}shutdown -r now${NC}"
}

### EJECUCIÓN PRINCIPAL ###########################################
main() {
    verify_stage3
    partition_disk
    prepare_system
    setup_chroot
    post_install
}

main
