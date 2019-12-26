#!/usr/bin/env bash

# Copyright (c) 2013-2019 Ross Smith II. All rights reserved. MIT licensed.

# @todo test backing up CFE: see note 9 on http://www.dd-wrt.com/phpBB2/viewtopic.php?t=51486
# @todo test backing up nvram
# from curl -d 'username=root&password=your-good-password' "http://router/cgi-bin/luci/admin/system/backup?backup=kthxbye" > `date +%Y%d%m`_config_backup.tgz
# backup openwrt via:
# @todo test backing up config settings on command line: see curl -d 'username=root&password=your-good-password' "http://router/cgi-bin/luci/admin/system/backup?backup=kthxbye" > `date +%Y%d%m`_config_backup.tgz

# set -o errexit
set -o nounset
set -o pipefail
# IFS=$'\n\t'

# set -x

EXCLUDE_DIRS='
  dev
  mmc
  mnt
  overlay
  proc
  rom
  sys
'

PROC_EXCLUDES='
  interrupts
  kallsyms
  kcore
  kmsg
'

TAR_DIRS='
  etc
  jffs
  opt
  tmp
  usr/local
  var
'

CMDS=(
  busybox
  dmesg
  fw_printenv
  hostid
  ifconfig
  lsmod
  lsusb
  mount
  ps
  set
  "uname -a"
)

IPTABLES='
  filter
  mangle
  nat
  raw
'

host="${1:-192.168.1.1}"
user="${2:-root}"

if [[ -f backup-wrt-config.sh ]]; then
  # shellcheck source=/dev/null
  . backup-wrt-config.sh
fi

userhost="${user}@${host}"

SSH="ssh -q ${userhost}"
TAR='tar -cf -'

hostname="$(${SSH} uname -n || true)"

if [[ -z "${hostname}" ]]; then
  hostname="$(${SSH} hostname || true)"
fi

if [[ -z "${hostname}" ]]; then
  hostname="${host}"
fi

DIR="backups/${hostname}/$(date +%F_%H-%M-%S)"

printf 'Backing up %s as %s to %s\n' "${host}" "${user}" "${DIR}"

mkdir -p "${DIR}"

pushd "${DIR}" >/dev/null || exit

${SSH} "test -f /tmp/loginprompt && cat /tmp/loginprompt" >loginprompt.txt

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

if [[ -z "${DONT_DUMP_MTDS:-}" ]]; then
  mtds="$(${SSH} cat /proc/mtd 2>/dev/null | grep mtd | cut -d':' -f 1)"
  for mtd in ${mtds}; do
    mtdname=${hostname}.${mtd}.bin

    if [[ -z "${DDWRT}" ]]; then
      MTD="/dev/${mtd}ro"
    else
      i="$(tr -d '0-9' <<<"${mtd}")"
      MTD="/dev/mtdblock/${i}"
    fi

    # echo dd if="${MTD}" "${mtdname}"
    ${SSH} dd if="${MTD}" >"${mtdname}" 2>/dev/null

    strings -n 8 "${mtdname}" >"${mtdname}-strings.txt"
  done
fi

for cmd in "${CMDS[@]}"; do
  ${SSH} "${cmd} 2>&1" >"${cmd}.txt"
done

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

PPROC_EXCLUDES="$(tr '\n\t\r' ' ' <<<"${PROC_EXCLUDES}" | tr -s ' ' | perl -pe 's/^\s*//; s/\s*$//;' | tr ' ' '|')"

PPROC_FILES="$(grep -E -v "/(${PPROC_EXCLUDES})$" <<<"${PROC_FILES}")"

mkdir -p proc

for path in ${PPROC_FILES}; do
  file="$(basename "${path}")"
  ${SSH} "cat '${path}' 2>/dev/null" >"proc/${file}.txt"
done

# openwrt <=10.03 / dd-wrt specific:

# /usr/sbin
${SSH} nvram show 2>/dev/null >nvram-show.txt

# openwrt <=10.03 specific:

PKG="$(${SSH} which opkg)"

if [[ -z "${PKG}" ]]; then
  PKG="$(${SSH} which ipkg)"
fi

${SSH} "${PKG}" list | sort -i >pkg-list.txt

# openwrt <=10.03 specific:

# /usr/sbin
if ${SSH} command -v nvram 2>/dev/null; then
  ${SSH} nvram info >nvram-info.txt
fi

# openwrt >10.03 specific:

# /sbin
${SSH} uci export >uci-export.txt
${SSH} uci show >uci-show.txt

${SSH} find /etc/config -name '*.orig'

# openwrt >10.03 / dd-wrt specific:

${SSH} "${PKG}" list-installed | sort -i >pkg-list-installed.txt

# | grep overlay$ | sed -e 's|.*/||' | cut -d. -f 1 | sort -u

# shellcheck disable=2089
cmd='/usr/bin/find /usr/lib/opkg/info -name "*.control" \( \( -exec test -f /rom/{} \; -exec echo {} rom \; \) -o \( -exec test -f /overlay/upper/{} \; -exec echo {} overlay \; \) -o \( -exec echo {} unknown \; \) \) | /bin/sed -e "s,.*/,,;s/\.control /\t/"'
# shellcheck disable=2059,2086,2090
${SSH} ${cmd} >installed_packages.txt

grep 'overlay$' installed_packages.txt | cut -f 1 | sort -u >user-installed_packages.txt

printf '#!/bin/sh\n' >install-user-packages.sh
printf '%s update\n' "${PKG}" >>install-user-packages.sh
sed "s|^|${PKG} install |" user-installed_packages.txt >>install-user-packages.sh
chmod +x install-user-packages.sh

# dd-wrt specific:

if [ -n "${DDWRT}" ]; then
  HOSTNAME_NVRAM="${hostname}.nvram"
  TMP_HOSTNAME_NVRAM="/tmp/${HOSTNAME_NVRAM}"

  ${SSH} rm -f "${TMP_HOSTNAME_NVRAM}"
  # /usr/sbin
  ${SSH} nvram backup "${TMP_HOSTNAME_NVRAM}"
  ${SSH} cat "${TMP_HOSTNAME_NVRAM}" >"${HOSTNAME_NVRAM}"
  ${SSH} rm -f "${TMP_HOSTNAME_NVRAM}"

  rm -f nvrambak.bin

  wget --http-user "${HTTP_USER}" --http-passwd "${HTTP_PASSWD}" "http://${host}/nvrambak.bin"
fi

# all OSs:

${SSH} "ls -lR / 2>/dev/null" >ls-root.txt

${SSH} "${TAR} -z \$(opkg list-changed-conffiles)" >list-changed-conffiles.tar.gz

${SSH} "${TAR} -z \$(grep -v -E '^\\s*#' /etc/sysupgrade.conf)" >sysupgrade-conffiles.tar.gz

${SSH} sysupgrade -l >sysupgrade-l.txt

${SSH} "${TAR} -z \$(sysupgrade -l)" >sysupgrade-l.tar.gz

for dir in ${TAR_DIRS}; do
  tarname="$(tr '/' '-' <<<"${dir}")"
  ${SSH} "test -d \"/${dir}\" && ${TAR} \"/${dir}\" 2>/dev/null" >"${tarname}.tar"
  if [[ -s "${tarname}.tar" ]]; then
    tar xf "${tarname}.tar"
  fi
done

PEXCLUDE_DIRS="$(tr '\n\t\r' ' ' <<<"${EXCLUDE_DIRS}" | tr -s ' ' | perl -pe 's/^\s*//; s/\s*$//;' | tr ' ' '|')"

DIRS="$(${SSH} ls -1 / 2>/dev/null | grep -E -v "^(${PEXCLUDE_DIRS})$" | perl -p -e 's|(.*)|/\1|' | tr '\n' ' ')"

${SSH} "${TAR} ${DIRS} 2>/dev/null" >root.tar

# openwrt compatible backup file:
# shellcheck disable=2086
${SSH} ${TAR} -z /etc >etc.tar.gz

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

popd >/dev/null || exit
printf 'Backup of %s as %s to %s completed successfully\n' "${host}" "${user}" "${DIR}"
# eof
