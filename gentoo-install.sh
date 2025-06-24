#!/bin/bash
set -e

# 🧑 Entradas interactivas
read -p "🧑‍💻 Nombre de usuario: " USERNAME
read -s -p "🔒 Contraseña de usuario: " USERPASS
echo
read -p "💻 Hostname (nombre del equipo): " HOSTNAME
read -p "🌍 Zona horaria (ej: America/Santiago): " TIMEZONE
read -p "🌐 Locale (ej: es_CL.UTF-8): " LOCALE
read -p "⌨️ Teclado (ej: latam): " KEYMAP
DISK="/dev/sdb"  # Cambia esto si usas otro disco

# 🔧 Particionado y formateo
echo "⚙️ Preparando disco $DISK..."
parted --script $DISK \
  mklabel gpt \
  mkpart primary fat32 1MiB 512MiB \
  set 1 esp on \
  mkpart primary ext4 512MiB 100%

mkfs.fat -F32 "${DISK}1"
mkfs.ext4 "${DISK}2"

mount "${DISK}2" /mnt/gentoo
mkdir -p /mnt/gentoo/boot
mount "${DISK}1" /mnt/gentoo/boot

# 📥 Descargar stage3
cd /mnt/gentoo
STAGE_URL=$(curl -s https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | awk '/tar.xz/ {print $1}')
wget "https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/$STAGE_URL"
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

# 🌐 Montajes y preparación para chroot
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

# 🚪 Entrar al entorno chroot y ejecutar instalación
cat << EOF | chroot /mnt/gentoo /bin/bash

source /etc/profile
export PS1="(chroot) \$PS1"

# 🛠️ make.conf
echo 'CFLAGS="-march=bdver3 -O2 -pipe"' >> /etc/portage/make.conf
echo 'CXXFLAGS="\${CFLAGS}"' >> /etc/portage/make.conf
echo 'MAKEOPTS="-j\$(nproc)"' >> /etc/portage/make.conf
echo 'GENTOO_MIRRORS="https://mirror.ufro.cl/gentoo/"' >> /etc/portage/make.conf

emerge-webrsync
eselect profile set default/linux/amd64/17.1/desktop/plasma
emerge --sync
emerge --update --deep --newuse @world

# 🌎 Zona horaria y localización
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set $LOCALE
env-update && source /etc/profile

echo "KEYMAP=\"$KEYMAP\"" > /etc/conf.d/keymaps
echo "$HOSTNAME" > /etc/hostname

# 🌐 Red cableada (modifica si es Wi-Fi)
echo 'config_enp3s0="dhcp"' >> /etc/conf.d/net
ln -s /etc/init.d/net.lo /etc/init.d/net.enp3s0
rc-update add net.enp3s0 default

# 🖥️ Entorno gráfico
emerge --ask x11-base/xorg-drivers x11-drivers/xf86-video-amdgpu
emerge --ask kde-plasma/plasma-meta sddm
echo 'DISPLAYMANAGER="sddm"' > /etc/conf.d/xdm
rc-update add xdm default

# 🔊 Audio con PipeWire
emerge --ask media-video/pipewire media-video/pipewire-alsa \
  media-video/pipewire-jack media-video/pipewire-pulse media-video/wireplumber
rc-update add pipewire default
rc-update add pipewire-pulse default

# 🧰 Servicios
rc-update add dbus default
rc-update add elogind default

# 👤 Crear usuario
useradd -m -G users,wheel,audio,video -s /bin/bash $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd
echo "$USERNAME ALL=(ALL:ALL) ALL" >> /etc/sudoers

# 💽 Instalar y configurar GRUB
emerge --ask sys-boot/grub:2 efibootmgr dosfstools
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=gentoo
grub-mkconfig -o /boot/grub/grub.cfg

echo "🎉 Instalación completa dentro del chroot."
EOF

echo "✅ ¡Todo listo! Puedes salir con 'exit' y reiniciar con 'reboot'"

