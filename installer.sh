#!/bin/bash
# Script de instalación Gentoo Linux - Versión 4.2 (Mejorada)
#
# NOTAS IMPORTANTES:
# 1. Este script DEBE ser ejecutado desde un LiveUSB de Gentoo.
# 2. Verifica las variables de hardware y localización en la CONFIGURACIÓN.
# 3. Se recomienda probarlo primero en una máquina virtual.

set -euo pipefail

### CONFIGURACIÓN ##################################################
DISK="/dev/sdb" # ¡VERIFICA ESTO CUIDADOSAMENTE CON `lsblk`!

# [FIX-v4.2] Simplificado. Solo necesitas la URL del stage3 más reciente.
# Búscala en: https://www.gentoo.org/downloads/ (sección OpenRC)
STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/20250622T165243Z/stage3-amd64-openrc-20250622T165243Z.tar.xz"

HOSTNAME="gentoo-linux"
USERNAME="oscar"
TIMEZONE="America/Santiago"
KEYMAP="la-latin1"
LOCALE="es_CL" # ej: es_CL, es_ES, en_US

### HARDWARE #######################################################
CPU_FLAGS="-march=steamroller -O2 -pipe" # Optimizado para AMD Kaveri/Steamroller
MAKEOPTS_J=$(( $(nproc) + 1 ))
SWAP_SIZE="8G"
VIDEO_CARDS="radeon amdgpu"
INPUT_DEVICES="libinput"

# [FIX-v4.2] Pool de mirrors para mayor robustez.
GENTOO_MIRRORS=(
    "https://distfiles.gentoo.org"
    "https://mirror.leaseweb.com/gentoo"
    "https://gentoo.osuosl.org"
)

### COLORES Y FUNCIONES ############################################
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; NC='\033[0m'

die() { echo -e "\n${RED}[ERROR]${NC} $1" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
run_chroot() { chroot /mnt/gentoo /bin/bash -c "set -e; source /etc/profile; ${1}"; }

### VALIDACIONES Y PREPARACIÓN INICIAL ##############################
# [FIX-v4.2] Función para verificar la conexión a internet.
check_internet() {
    info "Verificando conexión a internet..."
    if ! ping -c 1 -W 3 gentoo.org &>/dev/null; then
        die "No hay conexión a internet. Verifica tu red y vuelve a intentarlo."
    fi
    info "Conexión a internet confirmada."
}

# [FIX-v4.2] Función para pedir contraseñas de forma segura.
get_passwords() {
    info "Estableciendo contraseñas..."
    while true; do
        read -s -p "Introduce la contraseña para root: " ROOT_PASSWORD
        echo
        read -s -p "Confirma la contraseña para root: " ROOT_PASSWORD_CONFIRM
        echo
        [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ] && break
        warn "Las contraseñas no coinciden. Inténtalo de nuevo."
    done
    while true; do
        read -s -p "Introduce la contraseña para el usuario '$USERNAME': " USER_PASSWORD
        echo
        read -s -p "Confirma la contraseña para '$USERNAME': " USER_PASSWORD_CONFIRM
        echo
        [ "$USER_PASSWORD" = "$USER_PASSWORD_CONFIRM" ] && break
        warn "Las contraseñas no coinciden. Inténtalo de nuevo."
    done
}

[ "${EUID}" -ne 0 ] && die "Este script debe ser ejecutado como root."
[ ! -e "$DISK" ] && die "Disco $DISK no encontrado. Verifica la configuración."

if [[ "$DISK" == /dev/nvme* ]]; then
    PART_PREFIX="p"
else
    PART_PREFIX=""
fi
EFI_PART="${DISK}${PART_PREFIX}1"
SWAP_PART="${DISK}${PART_PREFIX}2"
ROOT_PART="${DISK}${PART_PREFIX}3"

### 1. PARTICIONADO ################################################
partition_disk() {
    info "Limpiando y creando tabla de particiones GPT en $DISK..."
    umount -R /mnt/gentoo &>/dev/null || true
    swapoff -a &>/dev/null || true
    sgdisk --zap-all "$DISK"
    parted -s "$DISK" mklabel gpt

    info "Creando particiones para UEFI..."
    parted -s -a optimal "$DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s -a optimal "$DISK" mkpart primary linux-swap 513MiB "calc(513MiB + ${SWAP_SIZE})"
    parted -s -a optimal "$DISK" mkpart primary ext4 "calc(513MiB + ${SWAP_SIZE})" 100%

    info "Formateando particiones..."
    mkfs.fat -F32 "$EFI_PART" || die "Error al formatear partición EFI."
    mkswap "$SWAP_PART" || die "Error al crear swap."
    mkfs.ext4 "$ROOT_PART" || die "Error al formatear partición raíz."

    info "Montando sistema de archivos..."
    mount "$ROOT_PART" /mnt/gentoo
    swapon "$SWAP_PART"
    mount --mkdir "$EFI_PART" /mnt/gentoo/boot
}

### 2. DESCARGA Y PREPARACIÓN DEL STAGE3 #############################
prepare_system() {
    local stage3_filename=$(basename "$STAGE3_URL")
    local stage3_local_path="/tmp/${stage3_filename}"

    info "Descargando stage3 a $stage3_local_path..."
    if [ ! -f "$stage3_local_path" ]; then
        wget -O "$stage3_local_path" -c "$STAGE3_URL" || die "Fallo al descargar stage3."
    else
        info "Stage3 ya existe en /tmp, usando el archivo local."
    fi

    info "Extrayendo stage3..."
    tar xpf "$stage3_local_path" -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner || die "Fallo al extraer stage3."

    info "Configurando make.conf..."
    cat > /mnt/gentoo/etc/portage/make.conf << EOF
COMMON_FLAGS="${CPU_FLAGS}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${MAKEOPTS_J}"
EMERGE_DEFAULT_OPTS="--jobs ${MAKEOPTS_J} --load-average $(nproc) --quiet-build --keep-going"

USE="X elogind dbus networkmanager pulseaudio alsa"
USE="\${USE} vaapi vdpau qt5 qt6 kde plasma sddm bluetooth -systemd -gnome"
VIDEO_CARDS="${VIDEO_CARDS}"
INPUT_DEVICES="${INPUT_DEVICES}"
GENTOO_MIRRORS="$(printf "'%s' " "${GENTOO_MIRRORS[@]}")"
EOF

    info "Configurando repositorios y DNS..."
    mkdir -p /mnt/gentoo/etc/portage/repos.conf
    cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
}

### 3. CONFIGURACIÓN EN CHROOT #####################################
configure_chroot() {
    info "Montando sistemas de archivos virtuales..."
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev

    info "Entrando en chroot para configurar el sistema..."

    run_chroot "emerge-webrsync && emerge --sync --quiet"
    run_chroot "eselect profile set default/linux/amd64/17.1/desktop/plasma"

    info "Configurando zona horaria y localización..."
    run_chroot "echo '$TIMEZONE' > /etc/timezone && emerge --config sys-libs/timezone-data"
    run_chroot "echo '${LOCALE}.UTF-8 UTF-8' >> /etc/locale.gen && locale-gen"
    run_chroot "eselect locale set ${LOCALE}.utf8 && env-update"

    info "Instalando kernel, firmware y herramientas críticas..."
    # [FIX-v4.2] Agrupando paquetes para una instalación más eficiente.
    run_chroot "emerge sys-kernel/gentoo-kernel-bin linux-firmware app-admin/sudo sys-boot/grub net-misc/networkmanager"

    info "Creando /etc/fstab..."
    cat > /mnt/gentoo/etc/fstab << FSTAB_EOF
${ROOT_PART}    /               ext4    defaults,noatime 0 1
${EFI_PART}     /boot           vfat    defaults,noatime 0 2
${SWAP_PART}    none            swap    sw              0 0
tmpfs /var/tmp/portage tmpfs size=8G,uid=portage,gid=portage,mode=775,noatime 0 0
FSTAB_EOF

    info "Configurando hostname y keymap..."
    run_chroot "echo 'hostname=\"$HOSTNAME\"' > /etc/conf.d/hostname"
    run_chroot "echo 'keymap=\"$KEYMAP\"' > /etc/conf.d/keymaps"

    info "Creando usuarios y estableciendo contraseñas..."
    run_chroot "echo 'root:${ROOT_PASSWORD}' | chpasswd"
    run_chroot "useradd -m -G wheel,audio,video,usb,portage -s /bin/bash '$USERNAME'"
    run_chroot "echo '${USERNAME}:${USER_PASSWORD}' | chpasswd"
    run_chroot "echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel"

    info "Instalando gestor de arranque GRUB para UEFI..."
    run_chroot "grub-install --target=x86_64-efi --efi-directory=/boot"
    run_chroot "grub-mkconfig -o /boot/grub/grub.cfg"

    info "Instalando entorno de escritorio Plasma y SDDM..."
    run_chroot "emerge kde-plasma/plasma-meta kde-apps/sddm-kcm"

    info "Habilitando servicios básicos..."
    run_chroot "rc-update add dbus default && rc-update add NetworkManager default && rc-update add sddm default"

    info "Configuración en chroot finalizada."
}

### 4. FINALIZACIÓN ################################################
post_install() {
    info "Desmontando todo..."
    umount -R /mnt/gentoo || warn "Algunas particiones no se desmontaron limpiamente."

    echo -e "\n${GREEN}¡Instalación completada!${NC}"
    echo "1. Revisa que no haya habido errores en la terminal."
    echo "2. Reinicia el sistema con: ${GREEN}shutdown -r now${NC}"
    echo "3. Se recomienda cambiar las contraseñas de nuevo como medida de seguridad."
    echo "4. Puedes instalar el resto de aplicaciones de KDE con: sudo emerge --ask kde-apps/kde-apps-meta"
}

### EJECUCIÓN PRINCIPAL ###########################################
main() {
    clear
    info "Iniciando script de instalación de Gentoo v4.2 (Mejorada)."
    read -p "Este script borrará TODO en ${DISK}. ¿Estás seguro? (escribe 'si' para continuar): " a
    [ "$a" != "si" ] && die "Instalación cancelada por el usuario."

    check_internet
    get_passwords
    partition_disk
    prepare_system
    configure_chroot
    post_install
}

main
