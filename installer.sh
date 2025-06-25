#!/bin/bash
# Script de instalación Gentoo Linux - Versión 5.7 CORREGIDA
# Soluciones integradas para:
# - Error de licencia linux-firmware
# - Requerimiento USE dracut para installkernel
# - Optimizado para AMD A8-7600B + KDE Plasma + PipeWire

set -euo pipefail

### CONFIGURACIÓN ##################################################
DISK="/dev/sdb"
STAGE3_LOCAL="/home/gentoo/Downloads/stage3-amd64-openrc-20250622T165243Z.tar.xz"
HOSTNAME="gentoo-amd"
USERNAME="oscar"
USER_FULLNAME="Oscar Vivanco"
TIMEZONE="America/Santiago"
KEYMAP="la-latin1"

### HARDWARE OPTIMIZADO AMD A8-7600B + 14GB RAM + SSD #############
CPU_FLAGS="-march=btver2 -O2 -pipe -fomit-frame-pointer"
SWAP_SIZE="2G"  # Reducido por tener 14GB RAM
VIDEO_CARDS="radeon"  # A8-7600B usa GPU integrada Radeon R7

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

# Función para solicitar contraseñas de forma segura
ask_passwords() {
    echo -e "${BLUE}=== Configuración de contraseñas ===${NC}"
    echo
    
    while true; do
        echo -e "${YELLOW}Ingresa la contraseña para el usuario root:${NC}"
        read -s ROOT_PASSWORD
        echo
        echo -e "${YELLOW}Confirma la contraseña para root:${NC}"
        read -s ROOT_PASSWORD_CONFIRM
        echo
        
        if [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ]; then
            if [ ${#ROOT_PASSWORD} -lt 6 ]; then
                warn "La contraseña debe tener al menos 6 caracteres. Intenta nuevamente."
                continue
            fi
            info "✓ Contraseña de root configurada"
            break
        else
            warn "Las contraseñas no coinciden. Intenta nuevamente."
        fi
    done
    
    echo
    while true; do
        echo -e "${YELLOW}Ingresa la contraseña para el usuario $USERNAME ($USER_FULLNAME):${NC}"
        read -s USER_PASSWORD
        echo
        echo -e "${YELLOW}Confirma la contraseña para $USERNAME:${NC}"
        read -s USER_PASSWORD_CONFIRM
        echo
        
        if [ "$USER_PASSWORD" = "$USER_PASSWORD_CONFIRM" ]; then
            if [ ${#USER_PASSWORD} -lt 6 ]; then
                warn "La contraseña debe tener al menos 6 caracteres. Intenta nuevamente."
                continue
            fi
            info "✓ Contraseña de $USERNAME configurada"
            break
        else
            warn "Las contraseñas no coinciden. Intenta nuevamente."
        fi
    done
    echo
}

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
    step "Particionando $DISK (GPT, EFI 512M, Swap 2G, Root resto)..."
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" mkpart primary linux-swap 513MiB 2561MiB
    parted -s "$DISK" mkpart primary ext4 2561MiB 100%
    
    step "Formateando particiones (optimizado para SSD):"
    mkfs.fat -F32 "${DISK}1" || die "Error al formatear EFI"
    mkswap "${DISK}2" || die "Error al crear swap"
    mkfs.ext4 -O ^has_journal -E lazy_itable_init=0,lazy_journal_init=0 "${DISK}3" || die "Error al formatear root"
    
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
MAKEOPTS="-j4 -l4"
USE="X elogind dbus networkmanager pipewire alsa vaapi qt5 qt6 kde plasma -systemd -pulseaudio sse3 sse4_1 sse4_2 ssse3 mmx"
VIDEO_CARDS="${VIDEO_CARDS}"
GENTOO_MIRRORS="$MIRROR_PRIMARY $MIRROR_SECONDARY"
FEATURES="parallel-fetch parallel-install compress-build-logs"
ACCEPT_LICENSE="* linux-fw-redistributable @BINARY-REDISTRIBUTABLE"
PORTAGE_NICENESS="15"
EMERGE_DEFAULT_OPTS="--jobs=2 --load-average=3.5"
EOF

    step "Configurando repositorios:"
    mkdir -p /mnt/gentoo/etc/portage/repos.conf
    cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf

    step "Preconfigurando USE flags requeridas:"
    mkdir -p /mnt/gentoo/etc/portage/package.use
    echo "sys-kernel/installkernel dracut" > /mnt/gentoo/etc/portage/package.use/installkernel

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
    mount --rbind /run /mnt/gentoo/run
    mount --make-rslave /mnt/gentoo/run
    
    # Crear script para ejecutar en chroot
    cat > /mnt/gentoo/install_chroot.sh << CHROOT_EOF
#!/bin/bash
set -euo pipefail

# Variables heredadas
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
USER_FULLNAME="$USER_FULLNAME"
ROOT_PASSWORD="$ROOT_PASSWORD"
USER_PASSWORD="$USER_PASSWORD"
TIMEZONE="$TIMEZONE"
MIRROR_PRIMARY="$MIRROR_PRIMARY"

# Funciones de ayuda
die() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }
info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

# Configurar entorno
source /etc/profile
export PS1="(chroot) ${PS1}"

# Sincronización inicial
info "Sincronizando repositorios Portage..."
if ! emerge-webrsync; then
    warn "emerge-webrsync falló, intentando con emerge --sync..."
    emerge --sync || die "¡Sincronización falló!"
fi

# Configuración adicional de licencias
info "Configurando licencias específicas..."
mkdir -p /etc/portage/package.license
echo "sys-kernel/linux-firmware linux-fw-redistributable @BINARY-REDISTRIBUTABLE" > /etc/portage/package.license/linux-firmware

# Configuración adicional de USE flags para AMD A8-7600B
info "Configurando USE flags específicos para AMD A8-7600B..."
mkdir -p /etc/portage/package.use
cat > /etc/portage/package.use/amd-optimized << EOF
# Kernel optimizado para A8-7600B
sys-kernel/installkernel dracut
sys-kernel/gentoo-kernel-bin -debug

# Mesa optimizado para Radeon R7 integrada
media-libs/mesa radeonsi gallium llvm vaapi vdpau

# X11 optimizado
x11-base/xorg-server glamor udev
x11-drivers/xf86-video-amdgpu glamor

# Multimedia optimizado
media-video/ffmpeg vaapi vdpau x264 x265
media-libs/libva vaapi vdpau

# Kernel y sistema
sys-kernel/linux-firmware radeon
sys-apps/util-linux caps

# Compilador optimizado
sys-devel/gcc lto pgo graphite
EOF

# Selección automática de perfil
info "Seleccionando perfil de escritorio..."
eselect profile set default/linux/amd64/23.0/desktop/plasma
info "Perfil seleccionado: default/linux/amd64/23.0/desktop/plasma"

# Configuración básica
info "Configurando zona horaria y locales..."
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data

# Configurar locales
cat > /etc/locale.gen << EOF
en_US.UTF-8 UTF-8
es_CL.UTF-8 UTF-8
EOF
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile

# Instalación del sistema base
info "Instalando componentes esenciales..."
emerge --oneshot sys-kernel/installkernel
emerge --oneshot sys-kernel/gentoo-kernel-bin
emerge --oneshot sys-kernel/linux-firmware

# Configuración del sistema
info "Configurando hostname y servicios básicos..."
echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname
echo 'keymap="la-latin1"' > /etc/conf.d/keymaps

# Configurar fstab con optimizaciones SSD y 14GB RAM
info "Configurando fstab optimizado para SSD..."
cat > /etc/fstab << FSTAB_EOF
# Particiones del sistema (optimizado para SSD)
/dev/sdb1		/boot		vfat		defaults,noatime,fmask=0022,dmask=0022	0 2
/dev/sdb2		none		swap		sw,pri=1				0 0
/dev/sdb3		/		ext4		noatime,discard,commit=60		0 1

# Sistemas de archivos virtuales
proc			/proc		proc		defaults				0 0
shm			/dev/shm	tmpfs		nodev,nosuid,noexec			0 0

# Optimización para compilación (aprovechando 14GB RAM)
tmpfs			/var/tmp/portage tmpfs	size=8G,uid=portage,gid=portage,mode=775	0 0
tmpfs			/tmp		tmpfs		size=4G,nodev,nosuid,noexec		0 0

# Cache en RAM para mejor rendimiento
tmpfs			/var/cache/distfiles tmpfs size=2G,uid=portage,gid=portage,mode=775 0 0
FSTAB_EOF

# Configurar usuarios
info "Configurando usuarios..."
echo "root:\$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,usb,portage -s /bin/bash -c "\$USER_FULLNAME" "\$USERNAME"
echo "\$USERNAME:\$USER_PASSWORD" | chpasswd

# Instalar sudo
emerge --oneshot app-admin/sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Servicios de red
info "Instalando NetworkManager..."
emerge --oneshot net-misc/networkmanager
rc-update add NetworkManager default

# Bootloader (UEFI)
info "Instalando GRUB..."
emerge --oneshot sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot
grub-mkconfig -o /boot/grub/grub.cfg

# Instalación básica de X11 y componentes gráficos
info "Instalando servidor X y controladores de video..."
emerge --oneshot x11-base/xorg-server
emerge --oneshot x11-drivers/xf86-video-amdgpu

# Instalar SDDM primero
info "Instalando SDDM..."
emerge --oneshot x11-misc/sddm
rc-update add sddm default

# Instalación de KDE Plasma (paso a paso para evitar errores)
info "Instalando KDE Plasma (esto tomará tiempo)..."
emerge --oneshot kde-frameworks/kf-env
emerge --oneshot kde-plasma/plasma-meta

# Configuración de PipeWire
info "Configurando PipeWire para audio..."
emerge --oneshot media-video/pipewire
emerge --oneshot media-video/wireplumber
emerge --oneshot media-libs/pipewire-jack

# Configuración de CPU para compilación optimizada
info "Configurando límites de CPU para evitar sobrecalentamiento..."
echo 'EMERGE_DEFAULT_OPTS="--jobs=2 --load-average=3.5"' >> /etc/portage/make.conf
echo 'PORTAGE_NICENESS="15"' >> /etc/portage/make.conf

# Optimizaciones específicas para SSD
info "Aplicando optimizaciones para SSD..."
echo 'vm.swappiness=10' >> /etc/sysctl.conf
echo 'vm.dirty_ratio=15' >> /etc/sysctl.conf
echo 'vm.dirty_background_ratio=5' >> /etc/sysctl.conf

# Crear directorio para cache en RAM
mkdir -p /var/cache/distfiles

# Limpieza final
info "Limpieza final..."
rm -f /install_chroot.sh

info "Configuración en chroot completada!"
CHROOT_EOF

    # Hacer ejecutable y ejecutar
    chmod +x /mnt/gentoo/install_chroot.sh
    step "Ejecutando configuración en chroot..."
    chroot /mnt/gentoo /bin/bash /install_chroot.sh
}

### POST-INSTALACIÓN ##############################################
post_install() {
    step "Desmontando particiones..."
    umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
    umount -R /mnt/gentoo 2>/dev/null || warn "Algunas particiones no se desmontaron limpiamente"
    
    echo -e "\n${GREEN}¡Instalación completada con éxito!${NC}"
    echo "================================================"
    echo " Configuración:"
    echo " - Hostname: $HOSTNAME"
    echo " - Usuario: $USERNAME ($USER_FULLNAME) [con sudo]"
    echo " - Entorno: KDE Plasma"
    echo " - Audio: PipeWire"
    echo " - Init: OpenRC"
    echo "================================================"
    echo -e "${YELLOW}Acciones post-instalación:${NC}"
    echo "1. Reiniciar el sistema:"
    echo -e "   ${GREEN}shutdown -r now${NC}"
    echo "2. Post-reinicio:"
    echo "   - Configurar red: nmtui"
    echo "   - Actualizar sistema: emerge --sync && emerge -uDU @world"
    echo "   - Las contraseñas ya están configuradas como solicitaste"
}

### EJECUCIÓN PRINCIPAL ###########################################
main() {
    echo -e "${GREEN}=== Instalador Gentoo para AMD A8-7600B ===${NC}"
    echo -e "Disco objetivo: ${YELLOW}$DISK${NC}"
    echo -e "Stage3 local: ${YELLOW}$STAGE3_LOCAL${NC}"
    echo -e "Usuario: ${YELLOW}$USERNAME ($USER_FULLNAME)${NC}"
    echo "------------------------------------------------"
    
    # Solicitar contraseñas antes de comenzar
    ask_passwords
    
    verify_stage3
    partition_disk
    install_system
    configure_chroot
    post_install
}

main
