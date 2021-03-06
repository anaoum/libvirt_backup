#!/bin/bash

set -e

DOMAIN="$1"
BACKUP_FOLDER="$2"
SNAPSHOT_NAME="$3"

export LIBVIRT_DEFAULT_URI="qemu:///system"

if [ -z "$DOMAIN" -o -z "$BACKUP_FOLDER" ]; then
    >&2 echo "Usage: $(basename $0) <domain> <backup-folder> [snapshot-name]"
    exit 1
fi
if [ -z "$SNAPSHOT_NAME" ]; then
    SNAPSHOT_NAME="$(date '+%Y%m%d%H%M%S')"
fi

if ! virsh dominfo "$DOMAIN" > /dev/null 2>&1; then
    >&2 echo "Domain '$DOMAIN' does not exist."
    exit 2
fi

BACKUP_LOCATION="$BACKUP_FOLDER/$DOMAIN"
mkdir -p "$BACKUP_LOCATION"

virsh dumpxml "$DOMAIN" > "$BACKUP_LOCATION/$DOMAIN.xml"

if virsh dominfo "$DOMAIN" | grep -q 'State:\s*running'; then
    if virsh domfsthaw "$1" >/dev/null 2>&1; then
        QUIESCE="--quiesce"
    else
        QUIESCE=""
    fi
    DISKSPEC="$(
    virsh domblklist "$DOMAIN" --details | sed -n 's/^file *disk *\([^ ]*\) *\(.*\)/\1:\2/p' | while IFS=: read -r target source; do
        echo -n " --diskspec $target,snapshot=external"
    done
    )"
    /usr/sbin/aa-complain "/etc/apparmor.d/libvirt/libvirt-$(virsh domuuid "$DOMAIN" | grep -v '^$')"
    virsh snapshot-create-as --domain "$DOMAIN" --name "$SNAPSHOT_NAME-TEMP.qcow2" --no-metadata --atomic $QUIESCE --disk-only $DISKSPEC
    /usr/sbin/aa-enforce "/etc/apparmor.d/libvirt/libvirt-$(virsh domuuid "$DOMAIN" | grep -v '^$')"
    virsh domblklist "$DOMAIN" --details | sed -n 's/^file *disk *\([^ ]*\) *\(.*\)/\1:\2/p' | while IFS=: read -r target source; do
        BACKUP_SRC="${source/$SNAPSHOT_NAME-TEMP./}"
        BACKUP_DST="$BACKUP_LOCATION/$target.$SNAPSHOT_NAME.qcow2"
        if [[ "$BACKUP_SRC" != *"nobackup"* ]]; then
            echo "Copying $BACKUP_SRC to $BACKUP_DST."
            cp "$BACKUP_SRC" "${BACKUP_DST}.tmp"
            echo "Reducing size of $BACKUP_DST."
            qemu-img convert -p -O qcow2 "${BACKUP_DST}.tmp" "$BACKUP_DST"
            rm -f "${BACKUP_DST}.tmp"
            echo "Changing permissions of $BACKUP_DST to 0400."
            chmod 0400 "$BACKUP_DST"
        fi
        echo "Committing from $source down to $BACKUP_SRC."
        virsh blockcommit "$DOMAIN" "$source" --base "$BACKUP_SRC" --pivot > /dev/null
        echo "Deleting temporary snapshot $source."
        rm -f "$source"
    done
else
    virsh domblklist "$DOMAIN" --details | sed -n 's/^file *disk *\([^ ]*\) *\(.*\)/\1:\2/p' | grep -v 'nobackup' | while IFS=: read -r target source; do
        BACKUP_SRC="$source"
        BACKUP_DST="$BACKUP_LOCATION/$target.$SNAPSHOT_NAME.qcow2"
        echo "Copying $BACKUP_SRC to $BACKUP_DST."
        qemu-img convert -p -O qcow2 "$BACKUP_SRC" "$BACKUP_DST"
        echo "Changing permissions of $BACKUP_DST to 0400."
        chmod 0400 "$BACKUP_DST"
    done
fi
