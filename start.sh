#!/bin/bash
# Сборщик Debian с Phosh для Lenovo Tab M10 HD 2nd Gen (TB-X306F)
# Требует: debootstrap, qemu-user-static, binfmt-support

set -e

# Конфигурация
DEBIAN_RELEASE="bookworm"
ARCH="arm64"
ROOTFS_DIR="debian-phosh-rootfs"
OUTPUT_DIR="output"
DEVICE="TB-X306F"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
    log_error "Запусти скрипт с sudo"
    exit 1
fi

# Проверка зависимостей
check_deps() {
    log_info "Проверка зависимостей..."
    local deps=("debootstrap" "qemu-user-static" "binfmt-support" "parted" "e2fsprogs")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null && ! dpkg -l | grep -q "$dep"; then
            log_error "Не найден: $dep"
            log_info "Установи: sudo apt install debootstrap qemu-user-static binfmt-support parted e2fsprogs"
            exit 1
        fi
    done
    log_info "Все зависимости на месте"
}

# Создание базового rootfs
create_rootfs() {
    log_info "Создание базового Debian $DEBIAN_RELEASE ($ARCH)..."
    
    if [ -d "$ROOTFS_DIR" ]; then
        log_warn "Директория $ROOTFS_DIR существует, удаляю..."
        umount_all
        rm -rf "$ROOTFS_DIR"
    fi
    
    mkdir -p "$ROOTFS_DIR"
    
    # Первый этап debootstrap
    debootstrap --arch=$ARCH --foreign $DEBIAN_RELEASE "$ROOTFS_DIR" http://deb.debian.org/debian/
    
    # Копируем qemu для второго этапа
    cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"
    
    # Второй этап в chroot
    chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage
    
    log_info "Базовая система создана"
}

# Настройка системы
configure_system() {
    log_info "Настройка системы..."
    
    # Монтируем необходимые файловые системы
    mount -t proc proc "$ROOTFS_DIR/proc"
    mount -t sysfs sys "$ROOTFS_DIR/sys"
    mount -o bind /dev "$ROOTFS_DIR/dev"
    mount -t devpts devpts "$ROOTFS_DIR/dev/pts"
    
    # Настройка sources.list
    cat > "$ROOTFS_DIR/etc/apt/sources.list" << EOF
deb http://deb.debian.org/debian $DEBIAN_RELEASE main contrib non-free non-free-firmware
deb http://deb.debian.org/debian $DEBIAN_RELEASE-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $DEBIAN_RELEASE-security main contrib non-free non-free-firmware
EOF
    
    # Настройка hostname
    echo "$DEVICE" > "$ROOTFS_DIR/etc/hostname"
    
    # Настройка hosts
    cat > "$ROOTFS_DIR/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   $DEVICE
::1         localhost ip6-localhost ip6-loopback
EOF
    
    # Настройка fstab для единого root раздела
    cat > "$ROOTFS_DIR/etc/fstab" << EOF
# <file system> <mount point> <type> <options> <dump> <pass>
/dev/mmcblk0p2  /               ext4    errors=remount-ro 0 1
/dev/mmcblk0p1  /boot           vfat    defaults          0 2
tmpfs           /tmp            tmpfs   defaults,nosuid   0 0
EOF
    
    log_info "Базовая конфигурация выполнена"
}

# Установка пакетов
install_packages() {
    log_info "Установка пакетов..."
    
    # Скрипт для выполнения в chroot
    cat > "$ROOTFS_DIR/tmp/install.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# Обновление
apt update
apt upgrade -y

# Базовые пакеты
apt install -y \
    systemd systemd-sysv udev \
    network-manager wpasupplicant \
    sudo vim nano htop \
    locales tzdata \
    ca-certificates gnupg wget curl \
    firmware-linux

# Русская локаль
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG=ru_RU.UTF-8

# Phosh и зависимости
apt install -y \
    phosh phosh-mobile-settings \
    gnome-shell-extension-phosh \
    gnome-software gnome-terminal \
    gnome-contacts gnome-calendar \
    evince eog gnome-calculator \
    file-roller nautilus \
    mobile-broadband-provider-info

# Wayland и Mesa для PowerVR
apt install -y \
    mesa-utils mesa-vulkan-drivers \
    xwayland libgl1-mesa-dri \
    libwayland-client0 libwayland-server0

# Звук
apt install -y \
    pulseaudio pulseaudio-utils \
    alsa-utils

# Сеть и Bluetooth
apt install -y \
    bluez blueman \
    network-manager-gnome

# Браузер и базовые приложения
apt install -y \
    firefox-esr \
    telegram-desktop \
    mpv \
    gimp

# Инструменты разработчика
apt install -y \
    git build-essential \
    python3 python3-pip \
    neofetch

# Клавиатура для touch
apt install -y squeekboard

# Автологин для пользователя user
mkdir -p /etc/lightdm/lightdm.conf.d/
cat > /etc/phosh/phosh.service.d/override.conf << EOF
[Service]
User=user
EOF

# Создание пользователя
useradd -m -G sudo,audio,video,input,plugdev,netdev -s /bin/bash user
echo "user:user" | chpasswd
echo "root:root" | chpasswd

# Sudo без пароля
echo "user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/user

# Включаем NetworkManager и Phosh
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable phosh

# Настройка автологина
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin user --noclear %I \$TERM
EOF

# Автозапуск Phosh при логине
mkdir -p /home/user/.config
cat > /home/user/.bash_profile << EOF
if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    exec phosh
fi
EOF
chown -R user:user /home/user

# Очистка
apt clean
rm -rf /var/lib/apt/lists/*

echo "Установка пакетов завершена"
CHROOT_EOF
    
    chmod +x "$ROOTFS_DIR/tmp/install.sh"
    chroot "$ROOTFS_DIR" /tmp/install.sh
    
    log_info "Пакеты установлены"
}

# Настройка драйверов и сенсора
configure_drivers() {
    log_info "Настройка драйверов..."
    
    # Конфигурация libinput для тачскрина
    mkdir -p "$ROOTFS_DIR/etc/udev/rules.d"
    cat > "$ROOTFS_DIR/etc/udev/rules.d/99-touchscreen.rules" << EOF
# Touchscreen configuration for TB-X306F
SUBSYSTEM=="input", ATTRS{name}=="*touchscreen*", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"
EOF
    
    # Модули ядра
    cat > "$ROOTFS_DIR/etc/modules-load.d/tablet.conf" << EOF
# Display and GPU
pvrsrvkm
# Touchscreen
fts_ts
# WiFi
wlan
# Audio
snd_soc_mt6768
EOF
    
    log_info "Драйверы настроены"
}

# Размонтирование
umount_all() {
    log_info "Размонтирование..."
    umount -l "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/sys" 2>/dev/null || true
}

# Создание образа
create_image() {
    log_info "Создание образа системы..."
    
    mkdir -p "$OUTPUT_DIR"
    
    # Размер образа (оставляем место для роста)
    IMG_SIZE="8G"
    
    # Создаём файл образа
    dd if=/dev/zero of="$OUTPUT_DIR/debian-phosh-$DEVICE.img" bs=1 count=0 seek=$IMG_SIZE
    
    # Создаём разделы
    parted -s "$OUTPUT_DIR/debian-phosh-$DEVICE.img" mklabel msdos
    parted -s "$OUTPUT_DIR/debian-phosh-$DEVICE.img" mkpart primary fat32 1MiB 100MiB
    parted -s "$OUTPUT_DIR/debian-phosh-$DEVICE.img" mkpart primary ext4 100MiB 100%
    parted -s "$OUTPUT_DIR/debian-phosh-$DEVICE.img" set 1 boot on
    
    # Монтируем образ
    LOOP_DEV=$(losetup -fP --show "$OUTPUT_DIR/debian-phosh-$DEVICE.img")
    
    # Форматируем
    mkfs.vfat -F 32 "${LOOP_DEV}p1"
    mkfs.ext4 -F "${LOOP_DEV}p2"
    
    # Монтируем и копируем
    mkdir -p /mnt/debian-img
    mount "${LOOP_DEV}p2" /mnt/debian-img
    mkdir -p /mnt/debian-img/boot
    mount "${LOOP_DEV}p1" /mnt/debian-img/boot
    
    log_info "Копирование rootfs в образ..."
    rsync -aAXv "$ROOTFS_DIR/" /mnt/debian-img/ --exclude=/proc/* --exclude=/sys/* --exclude=/dev/*
    
    sync
    umount /mnt/debian-img/boot
    umount /mnt/debian-img
    losetup -d "$LOOP_DEV"
    
    log_info "Образ создан: $OUTPUT_DIR/debian-phosh-$DEVICE.img"
}

# Создание архива rootfs
create_tarball() {
    log_info "Создание tarball rootfs..."
    
    mkdir -p "$OUTPUT_DIR"
    tar -czf "$OUTPUT_DIR/debian-phosh-rootfs-$DEVICE.tar.gz" -C "$ROOTFS_DIR" .
    
    log_info "Tarball создан: $OUTPUT_DIR/debian-phosh-rootfs-$DEVICE.tar.gz"
}

# Инструкции по установке
print_instructions() {
    cat << EOF

${GREEN}═══════════════════════════════════════════════════════════${NC}
${GREEN}    Debian Phosh для TB-X306F успешно собран!${NC}
${GREEN}═══════════════════════════════════════════════════════════${NC}

${YELLOW}Результаты сборки:${NC}
  • Rootfs: $ROOTFS_DIR/
  • Tarball: $OUTPUT_DIR/debian-phosh-rootfs-$DEVICE.tar.gz
  • Образ: $OUTPUT_DIR/debian-phosh-$DEVICE.img

${YELLOW}Следующие шаги:${NC}

${GREEN}1. Получить ядро от Ubuntu Touch порта${NC}
   Скачай boot.img от рабочего Ubuntu Touch порта для TB-X306F
   Источники: devices.ubuntu-touch.io или XDA forums

${GREEN}2. Прошивка через fastboot:${NC}
   
   # Разблокируй bootloader (если не разблокирован)
   fastboot oem unlock
   
   # Прошей образ системы
   fastboot flash system $OUTPUT_DIR/debian-phosh-$DEVICE.img
   
   # Прошей ядро от Ubuntu Touch
   fastboot flash boot boot.img
   
   # Перезагрузка
   fastboot reboot

${GREEN}3. Альтернативный метод (через TWRP recovery):${NC}
   
   # Распакуй tarball на раздел system
   adb push $OUTPUT_DIR/debian-phosh-rootfs-$DEVICE.tar.gz /sdcard/
   
   # В TWRP:
   # - Wipe system
   # - Advanced > Terminal
   mount /system
   cd /system
   tar -xzf /sdcard/debian-phosh-rootfs-$DEVICE.tar.gz
   
   # Прошей boot.img через TWRP

${YELLOW}Данные для входа:${NC}
  Пользователь: user
  Пароль: user
  Root пароль: root

${YELLOW}После загрузки:${NC}
  • Phosh запустится автоматически
  • Подключись к WiFi через настройки
  • Установи дополнительные пакеты: sudo apt install ...

${YELLOW}Важно:${NC}
  • Нужно ядро с драйверами для MT8768T
  • WiFi/BT модули должны быть в ядре
  • Для GPU используется mesa с PowerVR

${GREEN}Удачи!${NC}

EOF
}

# Главная функция
main() {
    log_info "Начинаем сборку Debian Phosh для $DEVICE"
    
    check_deps
    create_rootfs
    configure_system
    install_packages
    configure_drivers
    umount_all
    create_tarball
    create_image
    
    print_instructions
}

# Обработка Ctrl+C
trap 'log_error "Прервано пользователем"; umount_all; exit 1' INT TERM

main "$@"
