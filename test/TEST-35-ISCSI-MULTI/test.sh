#!/bin/bash

if [[ $NM ]]; then
    USE_NETWORK="network-manager"
    OMIT_NETWORK="network-legacy"
else
    USE_NETWORK="network-legacy"
    OMIT_NETWORK="network-manager"
fi

# shellcheck disable=SC2034
TEST_DESCRIPTION="root filesystem over multiple iSCSI with $USE_NETWORK"

KVERSION=${KVERSION-$(uname -r)}

#DEBUGFAIL="loglevel=1"
#DEBUGFAIL="rd.shell rd.break rd.debug loglevel=7 "
DEBUGFAIL="rd.debug loglevel=7 "
#SERVER_DEBUG="rd.debug loglevel=7"
#SERIAL="tcp:127.0.0.1:9999"

run_server() {
    # Start server first
    echo "iSCSI TEST SETUP: Starting DHCP/iSCSI server"

    "$testdir"/run-qemu \
        -drive format=raw,index=0,media=disk,file="$TESTDIR"/server.ext3 \
        -drive format=raw,index=1,media=disk,file="$TESTDIR"/root.ext3 \
        -drive format=raw,index=2,media=disk,file="$TESTDIR"/iscsidisk2.img \
        -drive format=raw,index=3,media=disk,file="$TESTDIR"/iscsidisk3.img \
        -serial "${SERIAL:-"file:$TESTDIR/server.log"}" \
        -net nic,macaddr=52:54:00:12:34:56,model=e1000 \
        -net nic,macaddr=52:54:00:12:34:57,model=e1000 \
        -net socket,listen=127.0.0.1:12331 \
        -append "panic=1 systemd.crash_reboot root=/dev/sda2 rootfstype=ext3 rw console=ttyS0,115200n81 selinux=0 $SERVER_DEBUG" \
        -initrd "$TESTDIR"/initramfs.server \
        -pidfile "$TESTDIR"/server.pid -daemonize || return 1
    chmod 644 "$TESTDIR"/server.pid || return 1

    # Cleanup the terminal if we have one
    tty -s && stty sane

    if ! [[ $SERIAL ]]; then
        while :; do
            grep Serving "$TESTDIR"/server.log && break
            echo "Waiting for the server to startup"
            tail "$TESTDIR"/server.log
            sleep 1
        done
    else
        echo Sleeping 10 seconds to give the server a head start
        sleep 10
    fi
}

run_client() {
    local test_name=$1
    shift
    echo "CLIENT TEST START: $test_name"

    dd if=/dev/zero of="$TESTDIR"/client.img bs=1M count=1

    "$testdir"/run-qemu \
        -drive format=raw,index=0,media=disk,file="$TESTDIR"/client.img \
        -net nic,macaddr=52:54:00:12:34:00,model=e1000 \
        -net nic,macaddr=52:54:00:12:34:01,model=e1000 \
        -net socket,connect=127.0.0.1:12331 \
        -append "panic=1 systemd.crash_reboot rw rd.auto rd.retry=50 console=ttyS0,115200n81 selinux=0 rd.debug=0 rd.shell=0 $DEBUGFAIL $*" \
        -initrd "$TESTDIR"/initramfs.testing
    if ! grep -U --binary-files=binary -F -m 1 -q iscsi-OK "$TESTDIR"/client.img; then
        echo "CLIENT TEST END: $test_name [FAILED - BAD EXIT]"
        return 1
    fi

    echo "CLIENT TEST END: $test_name [OK]"
    return 0
}

do_test_run() {
    initiator=$(iscsi-iname)
    run_client "netroot=iscsi target1 target2" \
        "root=LABEL=sysroot" \
        "ip=192.168.50.101:::255.255.255.0::ens2:off" \
        "ip=192.168.51.101:::255.255.255.0::ens3:off" \
        "netroot=iscsi:192.168.51.1::::iqn.2009-06.dracut:target1" \
        "netroot=iscsi:192.168.50.1::::iqn.2009-06.dracut:target2" \
        "rd.iscsi.initiator=$initiator" \
        || return 1

    run_client "netroot=iscsi target1 target2 rd.iscsi.waitnet=0" \
        "root=LABEL=sysroot" \
        "ip=192.168.50.101:::255.255.255.0::ens2:off" \
        "ip=192.168.51.101:::255.255.255.0::ens3:off" \
        "netroot=iscsi:192.168.51.1::::iqn.2009-06.dracut:target1" \
        "netroot=iscsi:192.168.50.1::::iqn.2009-06.dracut:target2" \
        "rd.iscsi.firmware" \
        "rd.iscsi.initiator=$initiator" \
        "rd.iscsi.waitnet=0" \
        || return 1

    run_client "netroot=iscsi target1 target2 rd.iscsi.waitnet=0 rd.iscsi.testroute=0" \
        "root=LABEL=sysroot" \
        "ip=192.168.50.101:::255.255.255.0::ens2:off" \
        "ip=192.168.51.101:::255.255.255.0::ens3:off" \
        "netroot=iscsi:192.168.51.1::::iqn.2009-06.dracut:target1" \
        "netroot=iscsi:192.168.50.1::::iqn.2009-06.dracut:target2" \
        "rd.iscsi.firmware" \
        "rd.iscsi.initiator=$initiator" \
        "rd.iscsi.waitnet=0 rd.iscsi.testroute=0" \
        || return 1

    run_client "netroot=iscsi target1 target2 rd.iscsi.waitnet=0 rd.iscsi.testroute=0 default GW" \
        "root=LABEL=sysroot" \
        "ip=192.168.50.101::192.168.50.1:255.255.255.0::ens2:off" \
        "ip=192.168.51.101::192.168.51.1:255.255.255.0::ens3:off" \
        "netroot=iscsi:192.168.51.1::::iqn.2009-06.dracut:target1" \
        "netroot=iscsi:192.168.50.1::::iqn.2009-06.dracut:target2" \
        "rd.iscsi.firmware" \
        "rd.iscsi.initiator=$initiator" \
        "rd.iscsi.waitnet=0 rd.iscsi.testroute=0" \
        || return 1

    echo "All tests passed [OK]"
    return 0
}

test_run() {
    if ! run_server; then
        echo "Failed to start server" 1>&2
        return 1
    fi
    do_test_run
    ret=$?
    if [[ -s $TESTDIR/server.pid ]]; then
        kill -TERM "$(cat "$TESTDIR"/server.pid)"
        rm -f -- "$TESTDIR"/server.pid
    fi
    return $ret
}

test_setup() {
    if ! command -v tgtd &> /dev/null || ! command -v tgtadm &> /dev/null; then
        echo "Need tgtd and tgtadm from scsi-target-utils"
        return 1
    fi

    # Create the blank file to use as a root filesystem
    rm -f "$TESTDIR"/root.ext3
    dd if=/dev/zero of="$TESTDIR"/root.ext3 bs=4096 count=$((200 * 256))
    rm -f "$TESTDIR"/iscsidisk2.img
    dd if=/dev/zero of="$TESTDIR"/iscsidisk2.img bs=4096 count=$((100 * 256))
    rm -f "$TESTDIR"/iscsidisk3.img
    dd if=/dev/zero of="$TESTDIR"/iscsidisk3.img bs=4096 count=$((100 * 256))

    kernel=$KVERSION
    # Create what will eventually be our root filesystem onto an overlay
    rm -rf -- "$TESTDIR"/overlay
    (
        # shellcheck disable=SC2030
        export initdir=$TESTDIR/overlay/source
        # shellcheck disable=SC1090
        . "$basedir"/dracut-init.sh
        (
            cd "$initdir" || exit
            mkdir -p -- dev sys proc etc var/run tmp
            mkdir -p root usr/bin usr/lib usr/lib64 usr/sbin
            for i in bin sbin lib lib64; do
                ln -sfnr usr/$i $i
            done
            mkdir -p -- var/lib/nfs/rpc_pipefs
        )
        inst_multiple sh shutdown poweroff stty cat ps ln ip \
            mount dmesg mkdir cp ping grep setsid dd sync
        for _terminfodir in /lib/terminfo /etc/terminfo /usr/share/terminfo; do
            [ -f ${_terminfodir}/l/linux ] && break
        done
        inst_multiple -o ${_terminfodir}/l/linux
        inst_simple /etc/os-release

        inst_simple "${basedir}/modules.d/99base/dracut-lib.sh" "/lib/dracut-lib.sh"
        inst_binary "${basedir}/dracut-util" "/usr/bin/dracut-util"
        ln -s dracut-util "${initdir}/usr/bin/dracut-getarg"
        ln -s dracut-util "${initdir}/usr/bin/dracut-getargs"

        inst ./client-init.sh /sbin/init
        cp -a /etc/ld.so.conf* "$initdir"/etc
        ldconfig -r "$initdir"
    )

    # second, install the files needed to make the root filesystem
    (
        # shellcheck disable=SC2031
        # shellcheck disable=SC2030
        export initdir=$TESTDIR/overlay
        # shellcheck disable=SC1090
        . "$basedir"/dracut-init.sh
        inst_multiple sfdisk mkfs.ext3 poweroff cp umount setsid dd sync blockdev
        inst_hook initqueue 01 ./create-client-root.sh
        inst_hook initqueue/finished 01 ./finished-false.sh
        inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
    )

    # create an initramfs that will create the target root filesystem.
    # We do it this way so that we do not risk trashing the host mdraid
    # devices, volume groups, encrypted partitions, etc.
    "$basedir"/dracut.sh -l -i "$TESTDIR"/overlay / \
        -m "dash crypt lvm mdraid udev-rules base rootfs-block fs-lib kernel-modules qemu" \
        -d "piix ide-gd_mod ata_piix ext3 sd_mod" \
        --no-hostonly-cmdline -N \
        -f "$TESTDIR"/initramfs.makeroot "$KVERSION" || return 1
    rm -rf -- "$TESTDIR"/overlay

    # Need this so kvm-qemu will boot (needs non-/dev/zero local disk)
    if ! dd if=/dev/zero of="$TESTDIR"/client.img bs=1M count=1; then
        echo "Unable to make client sdb image" 1>&2
        return 1
    fi
    # Invoke KVM and/or QEMU to actually create the target filesystem.
    "$testdir"/run-qemu \
        -drive format=raw,index=0,media=disk,file="$TESTDIR"/root.ext3 \
        -drive format=raw,index=1,media=disk,file="$TESTDIR"/client.img \
        -drive format=raw,index=2,media=disk,file="$TESTDIR"/iscsidisk2.img \
        -drive format=raw,index=3,media=disk,file="$TESTDIR"/iscsidisk3.img \
        -append "root=/dev/fakeroot rw rootfstype=ext3 quiet console=ttyS0,115200n81 selinux=0" \
        -initrd "$TESTDIR"/initramfs.makeroot || return 1
    grep -U --binary-files=binary -F -m 1 -q dracut-root-block-created "$TESTDIR"/client.img || return 1
    rm -- "$TESTDIR"/client.img

    # Make server root
    echo "MAKE SERVER ROOT"

    dd if=/dev/zero of="$TESTDIR"/server.ext3 bs=1M count=60

    export kernel=$KVERSION
    rm -rf -- "$TESTDIR"/overlay
    (
        mkdir -p "$TESTDIR"/overlay/source
        # shellcheck disable=SC2031
        # shellcheck disable=SC2030
        export initdir=$TESTDIR/overlay/source
        # shellcheck disable=SC1090
        . "$basedir"/dracut-init.sh
        (
            cd "$initdir" || exit
            mkdir -p dev sys proc etc var/run tmp var/lib/dhcpd /etc/iscsi
        )
        inst /etc/passwd /etc/passwd
        inst_multiple sh ls shutdown poweroff stty cat ps ln ip \
            dmesg mkdir cp ping \
            modprobe tcpdump setsid \
            /etc/services sleep mount chmod
        inst_multiple tgtd tgtadm
        for _terminfodir in /lib/terminfo /etc/terminfo /usr/share/terminfo; do
            [ -f ${_terminfodir}/l/linux ] && break
        done
        inst_multiple -o ${_terminfodir}/l/linux
        instmods iscsi_tcp crc32c ipv6
        [ -f /etc/netconfig ] && inst_multiple /etc/netconfig
        type -P dhcpd > /dev/null && inst_multiple dhcpd
        [ -x /usr/sbin/dhcpd3 ] && inst /usr/sbin/dhcpd3 /usr/sbin/dhcpd
        inst_simple /etc/os-release
        inst ./server-init.sh /sbin/init
        inst ./hosts /etc/hosts
        inst ./dhcpd.conf /etc/dhcpd.conf
        inst_multiple /etc/nsswitch.conf /etc/rpc /etc/protocols
        inst /etc/group /etc/group

        cp -a /etc/ld.so.conf* "$initdir"/etc
        ldconfig -r "$initdir"
        dracut_kernel_post
    )
    # second, install the files needed to make the root filesystem
    (
        # shellcheck disable=SC2031
        # shellcheck disable=SC2030
        export initdir=$TESTDIR/overlay
        # shellcheck disable=SC1090
        . "$basedir"/dracut-init.sh
        inst_multiple sfdisk mkfs.ext3 poweroff cp umount sync dd
        inst_hook initqueue 01 ./create-server-root.sh
        inst_hook initqueue/finished 01 ./finished-false.sh
        inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
    )

    # create an initramfs that will create the target root filesystem.
    # We do it this way so that we do not risk trashing the host mdraid
    # devices, volume groups, encrypted partitions, etc.
    "$basedir"/dracut.sh -l -i "$TESTDIR"/overlay / \
        -m "dash udev-rules base rootfs-block fs-lib kernel-modules fs-lib qemu" \
        -d "piix ide-gd_mod ata_piix ext3 sd_mod" \
        --nomdadmconf \
        --no-hostonly-cmdline -N \
        -f "$TESTDIR"/initramfs.makeroot "$KVERSION" || return 1

    # Invoke KVM and/or QEMU to actually create the target filesystem.
    "$testdir"/run-qemu \
        -drive format=raw,index=0,media=disk,file="$TESTDIR"/server.ext3 \
        -append "root=/dev/dracut/root rw rootfstype=ext3 quiet console=ttyS0,115200n81 selinux=0" \
        -initrd "$TESTDIR"/initramfs.makeroot || return 1
    grep -U --binary-files=binary -F -m 1 -q dracut-root-block-created "$TESTDIR"/server.ext3 || return 1
    rm -rf -- "$TESTDIR"/overlay

    # Make an overlay with needed tools for the test harness
    (
        # shellcheck disable=SC2031
        export initdir=$TESTDIR/overlay
        # shellcheck disable=SC1090
        . "$basedir"/dracut-init.sh
        inst_multiple poweroff shutdown
        inst_hook shutdown-emergency 000 ./hard-off.sh
        inst_hook emergency 000 ./hard-off.sh
        inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
    )

    # Make server's dracut image
    "$basedir"/dracut.sh -l -i "$TESTDIR"/overlay / \
        -a "dash udev-rules base rootfs-block fs-lib debug kernel-modules" \
        -d "af_packet piix ide-gd_mod ata_piix ext3 sd_mod e1000 drbg" \
        --no-hostonly-cmdline -N \
        -f "$TESTDIR"/initramfs.server "$KVERSION" || return 1

    # Make client's dracut image
    "$basedir"/dracut.sh -l -i "$TESTDIR"/overlay / \
        -o "dash plymouth dmraid nfs ${OMIT_NETWORK}" \
        -a "debug ${USE_NETWORK}" \
        -d "af_packet piix ide-gd_mod ata_piix ext3 sd_mod" \
        --no-hostonly-cmdline -N \
        -f "$TESTDIR"/initramfs.testing "$KVERSION" || return 1

    rm -rf -- "$TESTDIR"/overlay
}

test_cleanup() {
    if [[ -s $TESTDIR/server.pid ]]; then
        kill -TERM "$(cat "$TESTDIR"/server.pid)"
        rm -f -- "$TESTDIR"/server.pid
    fi
}

# shellcheck disable=SC1090
. "$testdir"/test-functions
