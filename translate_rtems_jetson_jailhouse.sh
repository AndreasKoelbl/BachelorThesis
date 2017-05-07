#!/bin/sh

### User variables ###
BASE_DIR="$(pwd)/$(dirname ${0})"
CPU_CORES=5
ARCH="arm"
CROSS_COMPILE="arm-linux-gnueabihf-"
TTY_DEFAULT="/dev/ttyUSB2"
ROOT_PASSWD="gentoo"
HOSTNAME="gauss"

### System variables ###
BOOT_DELAY=60
PORTAGE_DELAY=3600
UBOOT_SCRIPT="default_u-boot.script"
JH_UBOOT_SCRIPT="jh_u-boot.script"
CITY="$(readlink /etc/localtime | xargs basename)"
CONTINENT="$(dirname $(readlink /etc/localtime) | xargs basename)"
TIMEZONE="usr/share/zoneinfo/${CONTINENT}/${CITY}"
GENTOO_MIRROR="http://gentoo.oregonstate.edu/"
PORTAGE_PATH="snapshots/portage-latest.tar.bz2"
STAGE3_PATH="releases/arm/autobuilds/current-stage3-armv7a_hardfp/"
STAGE3_FILENAME="$(curl -s ${GENTOO_MIRROR}${STAGE3_PATH} | grep -Eo 'stage3-armv7a_hardfp-[0-9]*\.tar.bz2"'|grep -Eo 'stage3-armv7a_hardfp-[0-9]*\.tar.bz2')"
STAGE3_URL="${GENTOO_MIRROR}${STAGE3_PATH}${STAGE3_FILENAME}"
PORTAGE_URL="${GENTOO_MIRROR}${PORTAGE_PATH}"
USED_PROGS="sed mkimage openssl"
KERNEL_INSTALLED=0

function die()
{
    echo "$1"
    exit 1
}

function mount_prompt()
{
    echo "Please mount the jetson as USB mass storage device regarding the installed bootloader"
    echo "Using u-boot:"
    echo -e "\tPress the RESET-button of the jetson"
    echo -e "\tPress ENTER on the uart console (using e.g. screen)"
    echo -e "\tuntil the u-boot prompt appears"
    echo -e "\tInside the prompt type: ums 0 mmc 0"
    echo -e "\tConfirm with ENTER"
    echo -e "\tMount the jetson-TK1"
    echo -n "Please type in the folder you mounted your jetson to: "
    read mountpoint
    while [ ! -d "$mountpoint" ];
    do
        echo "$mountpoint does not exist"
        read mountpoint
    done
}

function prepare_gentoo()
{
    echo "Preparing rootfs"
    mkdir tmp
    cd tmp || die "cannot cd into tmp"
    PASS
    # Install gentoo on the jetson
    curl ${STAGE3_URL}|sudo tar -xvjp -C . || die "Stage3 init failed, check ${STAGE3_URL} if accessible"
    curl ${PORTAGE_URL}|sudo tar -xvjp -C usr || die "Portage init failed"
    sudo sh -c 'echo MAKEOPTS=\"$MAKEOPTS -j5\" > etc/portage/make.conf'
    HASH="$(openssl passwd \-1 ${ROOT_PASSWD})"
    ESCAPED_HASH=$(echo "$HASH" | sed -e 's/[\/&]/\\&/g');
    sudo sed -i "s/root.*/root:$ESCAPED_HASH:10770:0:::::/g" etc/shadow
    sudo sh -c 'echo "/dev/mmcblk0p1 / ext4 noatime 0 1" > etc/fstab'
    sudo sed -i 's/s0.*/s0:12345:respawn:\/sbin\/agetty -L 115200 ttyS0 vt100/g' etc/inittab
    sudo sh -c "echo \"hostname=${HOSTNAME}\" > etc/conf.d/hostname"
    sudo ln -sf ${TIMEZONE} etc/localtime
    sudo ln -sf net.lo etc/init.d/net.enp1s0
    sudo sh -c 'echo config_enp1s0=\"dhcp\" > etc/conf.d/net'
    sudo sh -c 'echo "PermitRootLogin yes" > etc/ssh/sshd_config'
    cd ${BASE_DIR}
    mount_prompt
    echo "Installing Gentoo on the Jetson TK1"
    sudo cp -av tmp/* ${mountpoint} || die "cannot copy rootfs"
    sudo mkimage -A arm -O linux -T script -C none -a 0x80000000 -e 0x80000000 -n Boot-Script -d ${UBOOT_SCRIPT} boot.scr || die "mkimage"
    sudo cp boot.scr ${mountpoint}/boot/
}

function setup_linux()
{
    mount_prompt
    cd ${BASE_DIR}/linux
    make tk1_jailhouse_root_defconfig
    make -j${CPU_CORES} || die "kernel compilation failed"
    sudo cp arch/arm/boot/zImage arch/arm/boot/dts/tegra124-jetson-tk1.dtb ${mountpoint}/boot/ || die "cannot copy images"
    mkdir modpath
    make modules_install INSTALL_MOD_PATH=${BASE_DIR}/linux/modpath || die "modules_install"
    sudo find ${BASE_DIR}/linux/modpath -type l -name build -exec rm -f {} \; -exec ln -sf /usr/src/linux {} \;
    sudo find ${BASE_DIR}/linux/modpath -type l -name "source" -exec rm -f {} \; -exec ln -sf /usr/src/linux {} \;
    sudo cp -R ${BASE_DIR}/linux/modpath/* ${mountpoint}/
    sudo cp -R ${BASE_DIR}/linux ${mountpoint}/usr/src
    KERNEL_INSTALLED=1
    echo "Unmounting $mountpoint"
    sudo umount "$mountpoint" || die "cannot umount $mountpoint"
    echo "$mountpoint unmounted, please reset your Jetson-TK1, release tty access and confirm with ENTER"
    read confirmation
}

function setup_uboot()
{
    cd ${BASE_DIR}/tegrarcm
    ./autogen.sh || die "autogen tegrarcm"
    make -j${CPU_CORES} || die "make tegrarcm"
    cd ..
    cd cbootimage
    ./autogen.sh || die "autogen cbootimage"
    make -j${CPU_CORES} || die "make cbootimage"
    cd ..
    export PATH=${PATH}:${BASE_DIR}/cbootimage/src:${BASE_DIR}/tegrarcm/src
    cd tegra-uboot-flasher-scripts
    ./build --socs tegra124 --boards jetson-tk1 build || die "tegra flasher scripts failed"
    echo -e "\n\n\n"
    echo "Preparation finished"
    echo "Please boot the jetson into recovery mode (by pressing FORCE RECOVERY + POWER)"
    echo "Confirm with ENTER"
    echo "$PATH"
    read confirmation
    sudo ./tegra-uboot-flasher --data-dir ../_out flash jetson-tk1 || die "flasher"
    cd ${BASE_DIR}
    echo "u-boot flashed successfully, now release the FORCE RECOVERY button"
    read confirmation
}

function setup_gentoo()
{
    while [ $(ps auxw | grep ttyUSB2 | wc -l) -gt 1 ];
    do
        echo "Please kill all processes accessing $TTY_DEFAULT: "
        ps auxw | grep "$TTY_DEFAULT" | grep -ve "grep"
        read confirmation
    done
    stty -F "$TTY_DEFAULT" 115200 raw
    echo "$TTY_DEFAULT"
    echo "root" > "$TTY_DEFAULT" || die "cannot access ${TTY_DEFAULT}"
    sleep 1
    echo "gentoo" > "$TTY_DEFAULT" || die "cannot access ${TTY_DEFAULT}"
    sleep 1
    echo "date --set=\"$(date -R)\"" > "$TTY_DEFAULT" || die "cannot access ${TTY_DEFAULT}"
    sleep 1
    echo 'ifconfig enp1s0 a.b.c.d' > ${TTY_DEFAULT} || die "cannot access ${TTY_DEFAULT}"
    sleep 1
    echo 'route add default gw a.b.c.e' > ${TTY_DEFAULT} || die "cannot access ${TTY_DEFAULT}"
    sleep 1
    echo 'echo nameserver 8.8.8.8 > /etc/resolv.conf' > ${TTY_DEFAULT} || die "cannot access ${TTY_DEFAULT}"
    sleep 1
    echo 'rc-update add sshd default' > ${TTY_DEFAULT} || die "cannot access ${TTY_DEFAULT}"
    sleep 2
    echo '/etc/init.d/sshd start' > ${TTY_DEFAULT} || die "cannot access ${TTY_DEFAULT}"
    sleep 3
    echo 'emerge --sync && emerge ntp bc && rc-update add ntp-client default' > ${TTY_DEFAULT} || die "Package installation failed"
    echo "Waiting ${PORTAGE_DELAY}s to install packages at $(date)"
    sleep $PORTAGE_DELAY
}

function setup_jetson()
{
    setup_uboot
    prepare_gentoo
    setup_linux
    echo "Waiting ${BOOT_DELAY}s for Linux to boot at $(date)"
    sleep $BOOT_DELAY
    setup_gentoo
}

function setup_jailhouse()
{
    cd ${BASE_DIR}
    echo -e "\033[0;31mPlease accept ssh host key and type in the password: $ROOT_PASSWD\033[0m"
    ssh-copy-id root@${HOSTNAME}
    sudo mkimage -A arm -O linux -T script -C none -a 0x80000000 -e 0x80000000 -n Boot-Script -d ${JH_UBOOT_SCRIPT} boot.scr || die "mkimage"
    scp boot.scr root@${HOSTNAME}:/boot/ || die "cannot connect to ${HOSTNAME}"
    if [ $KERNEL_INSTALLED -eq 0 ];
    then
        tar -czf - linux | ssh root@${HOSTNAME} '(cd /usr/src/ && tar xzf -)'
        scp -r jailhouse root@${HOSTNAME}:
    fi
    ssh root@${HOSTNAME} "cd /usr/src/linux && make -j${CPU_CORES} && make modules_prepare && cp arch/arm/boot/zImage arch/arm/boot/dts/tegra124-jetson-tk1.dtb /boot/" || die "cannot recompile on remote"
    ssh root@${HOSTNAME} "sudo shutdown -r +5 & disown"
    echo "Waiting ${BOOT_DELAY}s for Linux to boot at $(date)"
    sleep ${BOOT_DELAY}
    ssh root@${HOSTNAME} "cd jailhouse && make -j${CPU_CORES} && make install"
}

function setup_rtems()
{
    mkdir -p ${BASE_DIR}/rtems/compiler
    mkdir ${BASE_DIR}/rtems/bsps
    mkdir ${BASE_DIR}/rtems/build-jetsonTK1

    ls rtems/rtems-source-builder || die "submodule rtems-source-builder inactive"
    ${BASE_DIR}/rtems/rtems-source-builder/source-builder/sb-check || die "sb-check"
    cd ${BASE_DIR}/rtems/rtems-source-builder/rtems
    ../source-builder/sb-set-builder \
        --prefix=${BASE_DIR}/rtems/compiler/4.12 \
        --log=build-log.txt \
        4.12/rtems-arm || die "cannot install rtems environment"
    export PATH=${PATH}:${BASE_DIR}/rtems/compiler/4.12/bin
    cd ${BASE_DIR}/rtems/rtems-git/
    ./bootstrap -c || die "cannot bootstrap"
    ./bootstrap || die "cannot bootstrap"
    ./bootstrap -p || die "cannot bootstrap"
    cd ${BASE_DIR}/rtems/build-jetsonTK1 || die "cannot cd into build directory $BASE_DIR/rtems/build-jetsonTK1"
    rm -rf *
    ../rtems-gogs/configure --target=arm-rtems4.12 --enable-rtemsbsp=jetson-tk1 --enable-tests=yes --enable-posix -prefix=$(pwd)/../bsps/4.12
    rm -rf *
    ../rtems-gogs/configure --target=arm-rtems4.12 --enable-rtemsbsp=jetson-tk1 --enable-tests=yes --enable-posix -prefix=$(pwd)/../bsps/4.12
    make install -j${CPU_CORES}
    mkimage -A arm -T kernel -a 0x90000000 -e 0x90000000 -n ticker -O rtems -C none -d arm-rtems4.12/c/jetson-tk1/testsuites/samples/ticker/ticker.ralf ticker.uimage
    scp arm-rtems4.12/c/jetson-tk1/testsuites/samples/ticker/ticker.ralf root@${HOSTNAME}:jailhouse || die "cannot copy rtems to jailhouse, remote folder exists?"
    echo "load jailhouse/ticker.ralf on the address 0x80000000 and execute it"
    scp ticker.uimage root@${HOSTNAME}:/boot || die "cannot copy rtems to host, network attached?"
    echo "load /boot/ticker.uimage with u-boot on the address 0x80000000 and execute it"
    echo -e "Commands (on the u-boot console)\n"
    echo -e "\t ext2load mmc 0:1 0x80000000 /boot/ticker.uimage\n"
    echo -e "\t bootm 0x80000000"

    cd ${BASE_DIR}
}

function check_env()
{
    ### Check variables ###
    if [ -z "$CROSS_COMPILE" ];
    then
        echo "CROSS_COMPILE is not set, defaulting to ${CROSS_COMPILE_DEFAULT}"
        if ! $(hash ${CROSS_COMPILE_DEFAULT}gcc);
        then
            die "${CROSS_COMPILE_DEFAULT}gcc not found - please set CROSS_COMPILE"
        fi
        CROSS_COMPILE=${CROSS_COMPILE_DEFAULT}
        export CROSS_COMPILE=${CROSS_COMPILE}
    else
        echo $CROSS_COMPILE
    fi
    ### Check programs ###
    for prog in "$USED_PROGS";
    do
        if ! $(hash $prog);
        then
            die "Command not found: $prog"
        fi
    done
    git submodule init
    git submodule update
}

function ask_proc()
{
    if [ -z "$1" ];
    then
        die "ask_proc() error: parameter empty"
    fi

    echo "Setup the $1?"
    read answer
    if echo ${answer} | grep -iq "^y";
    then
        setup_$1
    fi
}

ARCH=arm
check_env

ask_proc jetson
ask_proc jailhouse
ask_proc rtems

export PATH=${PATH}:${BASE_DIR}/rtems/compiler/4.12
