#!/bin/bash

# Script de instalación automática de Gentoo Linux
# ADVERTENCIA: Este script formateará el disco especificado
# Usar bajo tu propia responsabilidad

set -e  # Salir si hay algún error

# Configuración inicial - Optimizado para AMD A8-7600B
DISK="/dev/sdb"  # SSD ubicado en /dev/sdb
HOSTNAME="gentoo-amd"
USERNAME="oscar"
ROOT_PASSWORD="gentoo123"
USER_PASSWORD="oscar123"
TIMEZONE="America/Santiago"
KEYMAP="la-latin1"  # Español Latinoamericano
TOTAL_RAM="14"  # GB de RAM disponible

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Verificar que se ejecuta como root
if [[ $EUID -ne 0 ]]; then
   error "Este script debe ejecutarse como root"
fi

log "Iniciando instalación de Gentoo Linux..."

# Sincronizar reloj
log "Sincronizando reloj del sistema..."
ntpd -s -q

# Particionar disco - Optimizado para SSD 256GB en /dev/sdb
log "Particionando disco $DISK (SSD 256GB en /dev/sdb)..."
parted -s $DISK mklabel gpt
parted -s $DISK mkpart primary fat32 1MiB 513MiB  # EFI más grande
parted -s $DISK set 1 boot on
parted -s $DISK mkpart primary linux-swap 513MiB 8705MiB  # 8GB swap (suficiente con 14GB RAM)
parted -s $DISK mkpart primary ext4 8705MiB 100%  # Resto para root

# Formatear particiones - Optimizado para SSD
log "Formateando particiones (optimizado para SSD)..."
mkfs.fat -F32 ${DISK}1
mkswap ${DISK}2
mkfs.ext4 -O ^has_journal ${DISK}3  # Sin journal para SSD, mejor rendimiento

# Montar particiones
log "Montando particiones..."
swapon ${DISK}2
mount ${DISK}3 /mnt/gentoo
mkdir -p /mnt/gentoo/boot
mount ${DISK}1 /mnt/gentoo/boot

# Descargar stage3
log "Descargando stage3..."
cd /mnt/gentoo
STAGE3_URL=$(curl -s https://www.gentoo.org/downloads/ | grep -o 'https://.*stage3-amd64-[0-9]*\.tar\.xz' | head -1)
if [ -z "$STAGE3_URL" ]; then
    STAGE3_URL="https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/current-stage3-amd64/stage3-amd64-$(date +%Y%m%d)T$(date +%H%M%S)Z.tar.xz"
fi

wget $STAGE3_URL -O stage3.tar.xz
tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner
rm stage3.tar.xz

# Configurar make.conf - Optimizado para AMD A8-7600B
log "Configurando make.conf para AMD A8-7600B..."
cat > /mnt/gentoo/etc/portage/make.conf << EOF
# CPU: AMD A8-7600B (Kaveri, 4 cores, 3.1GHz base, 3.8GHz boost)
COMMON_FLAGS="-march=bdver3 -O2 -pipe -fomit-frame-pointer"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

# Optimización para 4 cores + hyperthreading
MAKEOPTS="-j5 -l4"

# USE flags optimizados para AMD APU con gráficos Radeon R7 + KDE Plasma + PipeWire
USE="bindist mmx sse sse2 sse3 ssse3 sse4_1 sse4_2 avx fma3 fma4 popcnt aes"
USE="\${USE} radeon r600 gallium llvm opencl vaapi vdpau dbus pipewire sound-server"
USE="\${USE} X gtk qt5 qt6 kde plasma networkmanager wifi bluetooth usb"
USE="\${USE} plasma activities semantic-desktop kwallet phonon"
USE="\${USE} cups scanner jpeg png gif tiff pdf"
USE="\${USE} -nvidia -nouveau -gnome -systemd -pulseaudio -alsa"  # Excluir PulseAudio y ALSA en favor de PipeWire

# Configuración de video para Radeon R7 (GCN 1.0)
VIDEO_CARDS="radeon r600 radeonsi amdgpu"
INPUT_DEVICES="libinput synaptics"

# Configuración específica para SSD
FEATURES="parallel-fetch parallel-install"

GRUB_PLATFORMS="efi-64"
GENTOO_MIRRORS="https://mirror.eu.oneandone.net/linux/distributions/gentoo/gentoo/ https://mirror.rackspace.com/gentoo/"

ACCEPT_KEYWORDS="~amd64"
ACCEPT_LICENSE="*"

# Configuración de memoria (14GB RAM disponible)
PORTAGE_TMPDIR="/var/tmp"
EOF

# Configurar repositorios
log "Configurando repositorios..."
mkdir -p /mnt/gentoo/etc/portage/repos.conf
cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf

# Copiar información DNS
log "Copiando información DNS..."
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

# Montar sistemas de archivos necesarios
log "Montando sistemas de archivos..."
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# Entrar al entorno chroot y continuar instalación
log "Entrando al entorno chroot..."
cat > /mnt/gentoo/install_script_chroot.sh << 'CHROOT_SCRIPT'
#!/bin/bash

set -e

log() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

# Actualizar repositorio Portage
log "Sincronizando repositorio Portage..."
emerge-webrsync
emerge --sync --quiet

# Seleccionar perfil
log "Seleccionando perfil del sistema..."
eselect profile set default/linux/amd64/17.1/desktop/plasma  # KDE para mejor soporte AMD

# Actualizar world
log "Actualizando sistema base..."
emerge --update --deep --newuse @world

# Configurar zona horaria
log "Configurando zona horaria..."
echo "America/Santiago" > /etc/timezone
emerge --config sys-libs/timezone-data

# Configurar locales y teclado
log "Configurando locales y teclado español latinoamericano..."
cat > /etc/locale.gen << EOF
en_US.UTF-8 UTF-8
es_CL.UTF-8 UTF-8
es_ES.UTF-8 UTF-8
C.UTF-8 UTF-8
EOF

locale-gen
eselect locale set es_CL.utf8
env-update && source /etc/profile

# Configurar teclado español latinoamericano
echo 'keymap="la-latin1"' > /etc/conf.d/keymaps
rc-update add keymaps boot

# Instalar kernel
log "Instalando kernel con soporte AMD..."
emerge sys-kernel/linux-firmware  # Firmware para Radeon
emerge sys-kernel/installkernel-gentoo
emerge sys-kernel/gentoo-kernel-bin  # Kernel precompilado para rapidez

# Configurar módulos del kernel para AMD
log "Configurando módulos del kernel..."
cat > /etc/modules-load.d/amd.conf << EOF
# Módulos para AMD A8-7600B y Radeon R7
radeon
r600
amdgpu
k10temp  # Sensor de temperatura AMD
EOF

# Configurar fstab - Optimizado para SSD en /dev/sdb
log "Configurando fstab (optimizado para SSD en /dev/sdb)..."
cat > /etc/fstab << EOF
# Optimizado para SSD de 256GB en /dev/sdb
/dev/sdb1   /boot        vfat    defaults,noatime                    0 2
/dev/sdb2   none         swap    sw,discard                          0 0
/dev/sdb3   /            ext4    noatime,discard,relatime,errors=remount-ro 0 1

# Tmpfs para reducir escrituras en SSD (con 14GB RAM disponible)
tmpfs       /tmp         tmpfs   defaults,noatime,mode=1777,size=2G  0 0
tmpfs       /var/tmp/portage tmpfs defaults,noatime,mode=775,uid=portage,gid=portage,size=4G 0 0
EOF

# Configurar red
log "Configurando red..."
echo "hostname=\"gentoo-box\"" > /etc/conf.d/hostname
emerge --noreplace net-misc/netifrc
cat > /etc/conf.d/net << EOF
config_eth0="dhcp"
EOF
cd /etc/init.d
ln -s net.lo net.eth0
rc-update add net.eth0 default

# Configurar servicios del sistema
log "Configurando servicios del sistema..."
rc-update add sshd default
rc-update add dbus default
rc-update add NetworkManager default
rc-update add sddm default  # Display manager para KDE Plasma

# Instalar herramientas del sistema y KDE Plasma
log "Instalando herramientas del sistema..."
emerge app-admin/sysklogd
rc-update add sysklogd default
emerge sys-process/cronie
rc-update add cronie default
emerge sys-apps/mlocate
emerge net-misc/dhcpcd
emerge net-wireless/wpa_supplicant  # Para WiFi
emerge sys-power/cpupower  # Control de frecuencia CPU AMD
emerge lm-sensors  # Monitoreo de sensores
emerge app-admin/hddtemp  # Temperatura SSD

# Configurar cpupower para mejor rendimiento
log "Configurando cpupower para AMD A8-7600B..."
rc-update add cpupower default
echo 'cpupower_governor="ondemand"' > /etc/conf.d/cpupower

# Instalar PipeWire como sistema de audio
log "Instalando PipeWire como sistema de audio..."
emerge media-video/pipewire
emerge media-video/wireplumber  # Gestor de sesiones moderno para PipeWire
emerge media-sound/pipewire-pulse  # Compatibilidad con PulseAudio
emerge media-libs/libpulse  # Bibliotecas de compatibilidad

# Instalar KDE Plasma completo
log "Instalando KDE Plasma Desktop Environment..."
emerge kde-plasma/plasma-meta
emerge kde-apps/kde-apps-meta  # Aplicaciones básicas de KDE
emerge x11-misc/sddm  # Display Manager
emerge media-fonts/noto  # Fuentes Unicode completas
emerge app-office/libreoffice  # Suite de oficina
emerge www-client/firefox  # Navegador web

# Instalar bootloader
log "Instalando GRUB..."
emerge sys-boot/grub:2
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=gentoo
grub-mkconfig -o /boot/grub/grub.cfg

# Configurar usuarios y PipeWire
log "Configurando usuarios y PipeWire..."
echo "root:gentoo123" | chpasswd
useradd -m -G users,wheel,audio,cdrom,video,usb,portage,plugdev -s /bin/bash oscar
echo "oscar:oscar123" | chpasswd

# Configurar grupos adicionales para KDE y audio
usermod -a -G audio,video,usb,cdrom,plugdev,games,users oscar

# Configurar PipeWire para el usuario oscar
log "Configurando PipeWire para auto-inicio..."
mkdir -p /home/oscar/.config/systemd/user
chown -R oscar:oscar /home/oscar/.config

# Crear script de configuración de PipeWire para el usuario
cat > /home/oscar/.profile << 'EOF'
# Configuración de PipeWire
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [ -d "$XDG_RUNTIME_DIR" ]; then
    # Iniciar PipeWire si no está ejecutándose
    if ! pgrep -x "pipewire" > /dev/null; then
        pipewire &
        pipewire-pulse &
        wireplumber &
    fi
fi
EOF

chown oscar:oscar /home/oscar/.profile

# Instalar sudo
emerge app-admin/sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Configurar SDDM para KDE Plasma con PipeWire
log "Configurando SDDM Display Manager..."
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << EOF
[Autologin]
User=oscar
Session=plasma.desktop

[General]
Numlock=on

[Theme]
Current=breeze
EOF

# Configurar teclado español latinoamericano para X11
log "Configurando teclado para X11..."
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "latam"
    Option "XkbVariant" ""
    Option "XkbOptions" "terminate:ctrl_alt_bksp"
EndSection
EOF

# Configurar PipeWire como sistema de audio predeterminado
log "Configurando PipeWire como sistema de audio predeterminado..."
mkdir -p /etc/pipewire
cat > /etc/pipewire/pipewire.conf << EOF
# Configuración básica de PipeWire
context.properties = {
    default.clock.rate = 48000
    default.clock.quantum = 1024
    default.clock.min-quantum = 32
    default.clock.max-quantum = 8192
}

# Cargar módulos necesarios
context.modules = [
    { name = libpipewire-module-rtkit }
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-link-factory }
]
EOF

# Limpiar
log "Limpiando archivos temporales..."
rm /install_script_chroot.sh

log "¡Instalación completada!"
log "KDE Plasma Desktop configurado con teclado español latinoamericano"
log "Configuración:"
log "  Usuario root: gentoo123"
log "  Usuario: usuario / usuario123"
log "  Hostname: gentoo-box"
CHROOT_SCRIPT

chmod +x /mnt/gentoo/install_script_chroot.sh

# Ejecutar script en chroot
chroot /mnt/gentoo /install_script_chroot.sh

# Desmontar sistemas de archivos
log "Desmontando sistemas de archivos..."
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo

log "¡Instalación de Gentoo completada!"
log "Optimizado para AMD A8-7600B con KDE Plasma Desktop y PipeWire"
log "SSD instalado en /dev/sdb correctamente configurado"
log "Puedes reiniciar el sistema ahora."
log ""
log "Configuración optimizada:"
log "  - CPU: AMD A8-7600B (Kaveri) con optimizaciones bdver3"
log "  - GPU: Radeon R7 integrada con drivers radeon/amdgpu"
log "  - RAM: 14GB con tmpfs para compilación"
log "  - SSD: 256GB en /dev/sdb con optimizaciones discard y noatime"
log "  - Particiones: 512MB EFI, 8GB swap, resto para root"
log "  - Desktop: KDE Plasma con SDDM"
log "  - Audio: PipeWire con WirePlumber y compatibilidad PulseAudio"
log "  - Teclado: Español Latinoamericano (latam)"
log "  - Aplicaciones: LibreOffice, Firefox incluidas"
log ""
log "Credenciales por defecto:"
log "  Root: gentoo123"
log "  Usuario: oscar / oscar123"
log ""
warn "IMPORTANTE: Cambia las contraseñas después del primer inicio!"
warn "IMPORTANTE: El usuario 'oscar' tiene auto-login habilitado en SDDM!"
warn "IMPORTANTE: PipeWire se iniciará automáticamente al hacer login!"
warn "IMPORTANTE: Ejecuta 'sensors-detect' para configurar sensores!"
warn "IMPORTANTE: SSD correctamente configurado en /dev/sdb!"