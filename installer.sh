#!/bin/bash
# Script de instalación Gentoo Linux - Versión 5.5
# Corregido para errores de perfil + optimizado para AMD A8-7600B + KDE Plasma + PipeWire

set -euo pipefail

### CONFIGURACIÓN ##################################################
DISK="/dev/sdb"                                  # ¡VERIFICAR CON lsblk!
STAGE3_LOCAL="/home/gentoo/Downloads/stage3-amd64-openrc-20250622T165243Z.tar.xz"
HOSTNAME="gentoo-amd"
USERNAME="usuario"
ROOT_PASSWORD="gentoo123"                        # ¡Cambiar después!
USER_PASSWORD="usuario123"                       # ¡Cambiar después!
TIMEZONE="America/Santiago"
KEYMAP="la-latin1"

### HARDWARE #######################################################
CPU_FLAGS="-march=btver2 -O2 -pipe"              # AMD A8-7600B (Kaveri)
SWAP_SIZE="4G"                                   # Para 14GB RAM
VIDEO_CARDS="radeon amdgpu"                      # Radeon R7

### MIRRORS ########################################################
MIRROR_PRIMARY="https://mirror.leaseweb.com/gentoo"
MIRROR_SECONDARY="https://distfiles.gentoo.org"

### COLORES ########################################################
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'
NC='\033[0m'

### FUNCIONES ######################################################
die() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
step() { echo -e "${BLUE}[==>]${NC} $1"; }

### VALIDACIONES INICIALES #########################################
[ $EUID -ne 0 ] && die "Ejecutar como root"
[ ! -e "$DISK" ] && die "Disco $DISK no encontrado. Ejecuta 'lsblk' para verificar."
[ ! -f "$STAGE3_LOCAL" ] && die "Archivo stage3 no encontrado en:\n$STAGE3_LOCAL"
grep -q '/mnt/gentoo' /proc/mounts && die "/mnt/gentoo ya está montado"

### VERIFICACIÓN DEL STAGE3 ########################################
verify_stage3() {
    step "Verificando archivo stage3 local..."
    [ -r "$STAGE3_LOCAL" ] || die "Sin permisos para leer: $STAGE3_LOCAL"
    file "$STAGE3_LOCAL" | grep -q "XZ compressed data" || die "El archivo no es un .tar.xz válido"
    info "✓ Stage3 verificado"
}

### PARTICIONADO ##################################################
partition_disk() {
    step "Particionando $DISK (GPT, EFI 512M, Swap 4G, Root resto)..."
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" mkpart primary linux-swap 513MiB 4513MiB
    parted -s "$DISK" mkpart primary ext4 4513MiB 100%
    
    step "Formateando particiones:"
    mkfs.fat -F32 "${DISK}1" || die "Error al formatear EFI"
    mkswap "${DISK}2" || die "Error al crear swap"
    mkfs.ext4 -O ^has_journal "${DISK}3" || die "Error al formatear root"
    
    step "Montando sistema:"
    swapon "${DISK}2"
    mount "${DISK}3" /mnt/gentoo
    mkdir -p /mnt/gentoo/boot
    mount "${DISK}1" /mnt/gentoo/boot
}

### INSTALACIÓN DEL SISTEMA BASE ##################################
install_system() {
    step "Extrayendo stage3 directamente desde:"
    echo "   $STAGE3_LOCAL"
    cd /mnt/gentoo
    tar xpf "$STAGE3_LOCAL" --xattrs-include='*.*' --numeric-owner || die "Error al extraer stage3"
    
    step "Configurando make.conf optimizado:"
    cat > /mnt/gentoo/etc/portage/make.conf << EOF
COMMON_FLAGS="${CPU_FLAGS}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j4"
USE="X elogind dbus networkmanager pipewire alsa vaapi vdpau qt5 qt6 kde plasma"
VIDEO_CARDS="${VIDEO_CARDS}"
GENTOO_MIRRORS="$MIRROR_PRIMARY $MIRROR_SECONDARY"
FEATURES="parallel-fetch parallel-install"
EOF

    step "Configurando repositorios:"
    mkdir -p /mnt/gentoo/etc/portage/repos.conf
    cat > /mnt/gentoo/etc/portage/repos.conf/gentoo.conf << EOF
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = webrsync
sync-uri = $MIRROR_PRIMARY/releases/amd64/autobuilds/
auto-sync = yes
EOF

    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
}

### CONFIGURACIÓN EN CHROOT #######################################
configure_chroot() {
    step "Preparando entorno chroot..."
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    
    step "Ejecutando configuración en chroot..."
    chroot /mnt/gentoo /bin/bash << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail

# Funciones de ayuda
die() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }
info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

# Sincronización inicial (múltiples métodos de respaldo)
info "Sincronizando repositorios Portage..."
if ! emerge-webrsync; then
    warn "emerge-webrsync falló, intentando con mirror alternativo..."
    if ! emerge-webrsync --mirror="$MIRROR_PRIMARY"; then
        warn "Webrsync falló, intentando rsync..."
        emerge --sync || die "¡Todos los métodos de sincronización fallaron!"
    fi
fi

# Selección automática de perfil
info "Buscando perfil compatible..."
PROFILE=$(find /var/db/repos/gentoo/profiles -name make.defaults | grep -E 'default/linux/amd64/[0-9.]+' | sort -Vr | head -1 | xargs dirname)
PROFILE="${PROFILE#/var/db/repos/gentoo/profiles/}"
if [[ -z "$PROFILE" ]]; then
    die "No se encontró ningún perfil AMD64 válido"
fi
eselect profile set "$PROFILE"
info "Perfil seleccionado: $PROFILE"

# Configuración básica
info "Configurando zona horaria y locales..."
echo "America/Santiago" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "es_CL.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
eselect locale set es_CL.utf8
env-update && source /etc/profile

# Instalación del kernel
info "Instalando kernel precompilado..."
emerge sys-kernel/gentoo-kernel-bin linux-firmware

# Configuración del sistema
info "Configurando usuarios y servicios..."
echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname
echo 'keymap="la-latin1"' > /etc/conf.d/keymaps
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,usb -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
emerge app-admin/sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Bootloader (UEFI)
info "Instalando GRUB..."
emerge sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot
grub-mkconfig -o /boot/grub/grub.cfg

# Instalación de KDE Plasma
info "Instalando KDE Plasma..."
emerge kde-plasma/plasma-meta kde-apps/kde-apps-meta
emerge x11-misc/sddm

# Configuración de PipeWire
info "Configurando PipeWire para audio..."
emerge media-video/pipewire media-video/wireplumber media-sound/pipewire-pulse
rc-update delete pulseaudio default 2>/dev/null || true
rc-update add pipewire default
rc-update add wireplumber default
rc-update add pipewire-pulse default

# Servicios esenciales
info "Configurando servicios para inicio automático..."
rc-update add dbus default
rc-update add sddm default
rc-update add NetworkManager default
rc-update add sshd default

# Optimización SSD
info "Aplicando optimizaciones para SSD..."
sed -i '/\/ / s/defaults/noatime,discard,defaults/' /etc/fstab
echo "tmpfs /var/tmp/portage tmpfs size=4G,uid=portage,gid=portage,mode=775 0 0" >> /etc/fstab

# Limpieza final
rm /install_chroot.sh
CHROOT_EOF
}

### POST-INSTALACIÓN ##############################################
post_install() {
    step "Desmontando particiones..."
    umount -R /mnt/gentoo 2>/dev/null || warn "Algunas particiones no se desmontaron limpiamente"
    
    echo -e "\n${GREEN}¡Instalación completada con éxito!${NC}"
    echo "================================================"
    echo " Configuración:"
    echo " - Hostname: $HOSTNAME"
    echo " - Usuario: $USERNAME (con sudo)"
    echo " - Entorno: KDE Plasma"
    echo " - Audio: PipeWire"
    echo " - Init: OpenRC"
    echo "================================================"
    echo -e "${YELLOW}Acciones post-instalación:${NC}"
    echo "1. Cambiar contraseñas:"
    echo "   passwd root"
    echo "   passwd $USERNAME"
    echo "2. Reiniciar:"
    echo -e "   ${GREEN}shutdown -r now${NC}"
    echo "3. Post-reinicio:"
    echo "   - Configurar red: nmtui"
    echo "   - Actualizar sistema: emerge --sync && emerge -uDU @world"
}

### EJECUCIÓN PRINCIPAL ###########################################
main() {
    echo -e "${GREEN}=== Instalador Gentoo para AMD A8-7600B ===${NC}"
    echo -e "Disco objetivo: ${YELLOW}$DISK${NC}"
    echo -e "Stage3 local: ${YELLOW}$STAGE3_LOCAL${NC}"
    echo "------------------------------------------------"
    
    verify_stage3
    partition_disk
    install_system
    configure_chroot
    post_install
}

main
