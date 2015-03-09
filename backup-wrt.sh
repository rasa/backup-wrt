#!/usr/bin/env bash

# Copyright (c) 2013-2014 Ross Smith II. All rights reserved.

# @todo test backing up CFE: see note 9 on http://www.dd-wrt.com/phpBB2/viewtopic.php?t=51486
# @todo test backing up nvram
# from curl -d 'username=root&password=your-good-password' "http://router/cgi-bin/luci/admin/system/backup?backup=kthxbye" > `date +%Y%d%m`_config_backup.tgz
# backup openwrt via:
# @todo test backing up config settings on command line: see curl -d 'username=root&password=your-good-password' "http://router/cgi-bin/luci/admin/system/backup?backup=kthxbye" > `date +%Y%d%m`_config_backup.tgz

#set -e
set -x

EXCLUDE_DIRS="
  dev
  mmc
  mnt
  overlay
  proc
  rom
  sys
"

PROC_EXCLUDES="
  kmsg
  interrupts
"

TAR_DIRS="
  etc
  jffs
  opt
  tmp
  usr/local
"

CMDS="
  busybox
  dmesg
  hostid
  ifconfig
  lsmod
  lsusb
  mount
  ps
  set
"

IPTABLES="
  filter
  mangle
  nat
  raw
"

host="${1:-192.168.1.1}"
user="${2:-root}"

if [[ -f backup-wrt-config.sh ]]; then
  . backup-wrt-config.sh
fi

userhost="${user}@${host}"
remotepath="PATH=/bin:/sbin:/usr/bin:/usr/sbin"

SSH="ssh -q ${userhost} ${remotepath}"
TAR="tar -cf -"

hostname="$(${SSH} uname -n || true)"

if [[ -z "${hostname}" ]]; then
  hostname="$(${SSH} hostname || true)"
fi

if [[ -z "${hostname}" ]]; then
  hostname="${host}"
fi

DIR="backups/${hostname}/$(date +%F_%H-%M-%S)"

mkdir -p "${DIR}"

pushd "${DIR}"

${SSH} cat /tmp/loginprompt >loginprompt.txt

DDWRT="$(grep -qi dd-wrt loginprompt.txt && echo 1)"

# all OSs:

#CFE_BIN=cfe-backup.bin

#if [[ -z "${DDWRT}" ]]; then
#  MTD0=/dev/mtd0ro
#else
#  MTD0=/dev/mtdblock/0
#fi

#${SSH} dd if="${MTD0}" >"${CFE_BIN}"

#${SSH} dd if="${MTD0}" bs=1 skip=4116 count=2048 | strings >cfe-strings.txt

#strings -n 8 "${CFE_BIN}" >cfe-strings.txt

mtdnum=`${SSH} cat /proc/mtd | grep mtd | wc -l`

${SSH} cat /proc/mtd | grep mtd

for ((i=0; i<$mtdnum;i+=1))
do

mtdname=mtd$i"_`${SSH} cat /proc/mtd | grep mtd$i | sed  's/^mtd[0-9].*"\(.*\)"$/\1/' | tr " " "_"`"

if [[ -z "${DDWRT}" ]]; then
  MTD=/dev/mtd$i"ro"
else
  MTD=/dev/mtdblock/$i
fi

echo if="${MTD}" ${mtdname}.bin
${SSH} dd if="${MTD}" >"${mtdname}.bin"

strings -n 8 "${mtdname}.bin" >${mtdname}-strings.txt

done



for cmd in ${CMDS}; do
  ${SSH} "${cmd}" >"${cmd}.txt"
done

${SSH} uname -a >uname.txt

for table in ${IPTABLES}; do
  # /usr/sbin
  ${SSH} iptables -t "${table}" -vnxL >"iptables-${table}.txt"
  # /usr/sbin
  ${SSH} iptables-save -t "${table}" >"iptables-save-${table}.txt"
done

if [ -z "${DDWRT}" ]; then
  PROC_FILES="$(${SSH} find /proc -type f -maxdepth 1 | sort)"
else
  PROC_FILES="$(${SSH} find /proc -type f | grep -v '/.*/.*/' | sort)"
fi

PPROC_EXCLUDES="$(echo "${PROC_EXCLUDES}" | tr "\n\t\r" ' ' | tr -s ' ' | perl -pe 's/^\s*//; s/\s*$//;' | tr ' ' '|')"

PPROC_FILES="$(echo "${PROC_FILES}" | egrep -v "/(${PPROC_EXCLUDES})$")"

mkdir -p proc

for path in ${PPROC_FILES}; do
  file="$(basename "${path}")"
  ${SSH} cat "${path}" >"proc/${file}.txt"
done

# openwrt <=10.03 / dd-wrt specific:

# /usr/sbin
${SSH} nvram show >nvram-show.txt

# openwrt <=10.03 specific:

PKG="$(${SSH} which opkg)"

if [[ -z "${PKG}" ]]; then
  PKG="$(${SSH} which ipkg)"
fi

${SSH} "${PKG}" list | sort -i >pkg-list.txt

# openwrt <=10.03 specific:

# /usr/sbin
${SSH} nvram info >nvram-info.txt

# openwrt >10.03 specific:

# /sbin
${SSH} uci export >uci-export.txt
${SSH} uci show >uci-show.txt

# openwrt >10.03 / dd-wrt specific:

${SSH} "${PKG}" list-installed | sort -i >pkg-list-installed.txt

# dd-wrt specific:

HOSTNAME_NVRAM="${hostname}.nvram"
TMP_HOSTNAME_NVRAM="/tmp/${HOSTNAME_NVRAM}"

${SSH} rm -f "${TMP_HOSTNAME_NVRAM}"
# /usr/sbin
${SSH} nvram backup "${TMP_HOSTNAME_NVRAM}"
${SSH} cat "${TMP_HOSTNAME_NVRAM}" >"${HOSTNAME_NVRAM}"
${SSH} rm -f "${TMP_HOSTNAME_NVRAM}"

rm -f nvrambak.bin

if [[ -n "${DDWRT}" ]]; then
  wget --http-user "${HTTP_USER}" --http-passwd "${HTTP_PASSWD}" "http://${host}/nvrambak.bin"
fi

# all OSs:

${SSH} ls -lR / >ls-root.txt

for dir in ${TAR_DIRS}; do
  tarname="$(echo "${dir}" | tr / -)"
  ${SSH} "test -d \"/${dir}\" && ${TAR} \"/${dir}\"" >"${tarname}.tar"
  if [[ -s "${tarname}.tar" ]]; then
    tar xf "${tarname}.tar"
  fi
done

PEXCLUDE_DIRS="$(echo "${EXCLUDE_DIRS}" | tr "\n\t\r" ' ' | tr -s ' ' | perl -pe 's/^\s*//; s/\s*$//;' | tr ' ' '|')"

DIRS="$(${SSH} ls -1 / 2>/dev/null | egrep -v "^(${PEXCLUDE_DIRS})$" | perl -p -e 's|(.*)|/\1|' | tr '\n' ' ')"

${SSH} ${TAR} ${DIRS} >root.tar

# openwrt compatible backup file:

BACKUP="backup-${hostname}-$(date +%F).tar.gz"
${SSH} ${TAR} -z /etc >"${BACKUP}"

#if [[ -z "${DDWRT}" ]]; then
# EXCLUDE_LST=/tmp/exclude.lst
# echo -e "dev\noverlay\nproc\nrom\nsys\n" | ${SSH} "cat - >\"${EXCLUDE_LST}\""
# TAR="${TAR} -X \"${EXCLUDE_LST}\""
#fi
#
#${SSH} ${TAR} / >root.tar
#
#if [[ -z "${DDWRT}" ]]; then
# ${SSH} rm -f "${EXCLUDE_LST}"
#fi

popd

# eof

