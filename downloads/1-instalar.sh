#!/usr/bin/env bash
#===============================================================================
#  1-instalar.sh  ·  Pi-Pineapple · PASO 1: instalar el SO en la microSD
#
#  Un solo script que, con el USB/lector ya conectado:
#    1) comprueba herramientas y dependencias
#    2) elige SO (Kali por defecto) y detecta la ÚLTIMA imagen automáticamente
#    3) descarga + verifica SHA-256 + descomprime
#    4) HORNEA el auto-conectado (WiFi + clave SSH + baliza mDNS)
#    5) autodetecta la microSD, confirma (x2) y graba
#
#  Interfaz "pantalla por paso": la vista se redibuja en el sitio, con cabecera
#  fija y barra de progreso, en vez de ir llenando la terminal.
#
#  Después: mete la microSD en la Pi, dale corriente y lanza  ./2-cazar.sh
#
#  ⚠️  dd escribe a bajo nivel. Elegir el disco equivocado lo destruye → hay
#      detección del disco de sistema + doble confirmación.
#  ⚠️  Solo para TU laboratorio / TU red WiFi / pentest autorizado por escrito.
#===============================================================================
set -uo pipefail

#--- Colores ------------------------------------------------------------------
G='\033[1;32m'; C='\033[1;36m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1;34m'
DIM='\033[2m'; BOLD='\033[1m'; N='\033[0m'
ok()   { echo -e "   ${G}✓${N} $1"; }
info() { echo -e "   ${B}i${N} $1"; }
warn() { echo -e "   ${Y}!${N} $1"; }
err()  { echo -e "   ${R}✗${N} $1"; }
die()  { err "$1"; echo; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1; }
cls(){ printf '\033[2J\033[3J\033[H'; }
# Foto de los discos presentes (para detectar el que enchufes DESPUÉS de arrancar).
disk_snapshot(){ lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | sort; }

WORKDIR="${HOME}/pi-images"
KEY="$HOME/.ssh/pi_pineapple_lab"
STEP_TOTAL=9

#--- Cabecera de pantalla (se redibuja en cada paso) --------------------------
hdr(){
  local n="$1" title="$2" bar="" i
  cls
  for ((i=1;i<=STEP_TOTAL;i++)); do
    if   ((i<n));  then bar+="${G}●${N}"
    elif ((i==n)); then bar+="${C}◉${N}"
    else                bar+="${DIM}·${N}"; fi
  done
  echo
  echo -e "  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "   ${BOLD}🍍 Pi-Pineapple${N} ${DIM}· instalador de sistema en microSD${N}"
  echo -e "   ${bar}   ${DIM}paso ${n}/${STEP_TOTAL}${N}"
  echo -e "  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "   ${BOLD}${title}${N}"
  echo
}

#--- Spinner en el sitio mientras un PID trabaja ------------------------------
spin_wait(){   # $1=pid  $2=mensaje
  local sp='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$1" 2>/dev/null; do
    i=$(((i+1)%10)); printf "\r   ${C}%s${N} %s" "${sp:$i:1}" "$2"; sleep 0.1
  done
  printf "\r\033[K"
}

#==============================================================================
# PASO 1 · Preparación
#==============================================================================
hdr 1 "Preparación · sistema y dependencias"
[[ "$(uname -s)" == "Linux" ]] || die "Este script es para Linux (en Windows: WSL o Raspberry Pi Imager)."
[[ $EUID -eq 0 ]] && SUDO="" || SUDO="sudo"

DL=""; need curl && DL="curl" || { need wget && DL="wget"; }
[[ -z "$DL" ]] && die "Necesito curl o wget."
for c in xz xzcat lsblk losetup openssl ssh-keygen partprobe findmnt mktemp dd sudo; do
  need "$c" || die "Falta '$c'. Instala el paquete correspondiente y reintenta."
done
if need sha256sum; then SHA_CMD="sha256sum"; elif need shasum; then SHA_CMD="shasum -a 256"; else SHA_CMD=""; fi
ok "Dependencias base OK ${DIM}(descarga: ${DL} · grabado: dd)${N}"

FLASHER_GUI=""
for t in rpi-imager balena-etcher balenaEtcher etcher; do need "$t" && { FLASHER_GUI="$t"; break; }; done
[[ -n "$FLASHER_GUI" ]] && info "Herramienta gráfica presente: ${BOLD}$FLASHER_GUI${N} ${DIM}(igual grabamos con dd)${N}" \
                        || info "Sin rpi-imager/balenaEtcher → se graba con ${BOLD}dd${N} ${DIM}(mismo resultado)${N}"
mkdir -p "$WORKDIR"
DISKS_AT_START="$(disk_snapshot)"   # lo que había conectado al arrancar el script
echo; read -rp "   ↵ Enter para empezar... " _

#==============================================================================
# PASO 2 · Sistema operativo
#==============================================================================
hdr 2 "¿Qué sistema instalar en la Pi?"
echo -e "   ${C}1)${N} ${BOLD}Kali Linux ARM${N}  ${DIM}— recomendado (el del vídeo); parte del arsenal WiFi (hostapd/mdk4/hcxdumptool/bettercap) se instala luego${N}"
echo -e "   ${C}2)${N} Raspberry Pi OS Lite (Trixie)  ${DIM}— ligero; el arsenal se instala luego${N}"
echo
read -rp "   Elige [1-2] (Enter=1) › " osopt; osopt="${osopt:-1}"
case "$osopt" in
  1) DISTRO="kali" ;;
  2) DISTRO="rpios" ;;
  *) die "Opción no válida." ;;
esac
echo
read -rp "   ¿Tu Raspberry Pi es la 4 o la 5? [4/5] › " PIMODEL
case "$PIMODEL" in
  5) warn "Pi 5: usa fuente/power bank ${BOLD}USB-PD 5V/5A${N}. Con 5V/3A el firmware capa los USB a 600 mA y el Alfa puede dar brownouts." ;;
  4) info "Pi 4: 5V/3A basta. ${DIM}(La imagen es la misma para 4 y 5.)${N}" ;;
  *) info "Sin especificar; la imagen sirve para Pi 4 y Pi 5 igualmente." ;;
esac
sleep 1

#==============================================================================
# PASO 3 · Buscar la última imagen
#==============================================================================
hdr 3 "Buscando la última imagen disponible"
IMG_URL=""; SHA_URL=""; SHA_KIND=""; IMG_NAME=""
fetch(){ if [[ "$DL" == "curl" ]]; then curl -Ls --fail "$1"; else wget -qO- "$1"; fi; }

if [[ "$DISTRO" == "kali" ]]; then
  KBASE="https://kali.download/arm-images/"
  info "Leyendo el índice de Kali para detectar la última release..."
  LATEST_DIR=""
  fetch "$KBASE" > /tmp/kali-idx.$$ 2>/dev/null & spin_wait $! "Consultando kali.download…"
  LATEST_DIR="$(grep -oE 'kali-[0-9]{4}\.[0-9]+/' /tmp/kali-idx.$$ 2>/dev/null | sort -V | uniq | tail -1)"
  rm -f /tmp/kali-idx.$$
  if [[ -z "$LATEST_DIR" ]]; then
    warn "No pude leer el índice automáticamente."
    read -rp "   Versión de Kali a mano (ej. 2026.2) › " KV
    [[ -z "$KV" ]] && die "Sin versión no puedo continuar."
    LATEST_DIR="kali-${KV}/"
  fi
  KVER="${LATEST_DIR#kali-}"; KVER="${KVER%/}"
  IMG_NAME="kali-linux-${KVER}-raspberry-pi-arm64.img.xz"
  IMG_URL="${KBASE}${LATEST_DIR}${IMG_NAME}"
  SHA_URL="${KBASE}${LATEST_DIR}SHA256SUMS"; SHA_KIND="sums"
  ok "Kali detectado: ${BOLD}${KVER}${N} ${DIM}(imagen única Pi 3/4/5)${N}"
else
  IMG_URL="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"
  IMG_NAME="raspios-lite-arm64.img.xz"
  if [[ "$DL" == "curl" ]]; then
    FINAL="$(curl -Ls -o /dev/null -w '%{url_effective}' "$IMG_URL" 2>/dev/null || echo "$IMG_URL")"
    SHA_URL="${FINAL}.sha256"; SHA_KIND="single"
  fi
  ok "Raspberry Pi OS Lite ${DIM}(última vía _latest)${N}"
fi
echo; info "${DIM}${IMG_URL}${N}"
sleep 1

#==============================================================================
# PASO 4 · Descargar
#==============================================================================
hdr 4 "Descargando la imagen"
IMG_XZ="${WORKDIR}/${IMG_NAME}"
if [[ -f "$IMG_XZ" ]]; then
  info "Ya existe ${DIM}${IMG_XZ}${N} ($(du -h "$IMG_XZ" | cut -f1))."
  read -rp "   ¿Volver a descargar? [s/N] › " r; [[ "${r,,}" == "s" ]] && rm -f "$IMG_XZ"
fi
if [[ ! -f "$IMG_XZ" ]]; then
  info "Descargando (barra en el sitio):"
  echo
  if [[ "$DL" == "curl" ]]; then curl -L --fail --progress-bar -o "$IMG_XZ" "$IMG_URL" || die "Fallo en la descarga.";
  else wget -q --show-progress -O "$IMG_XZ" "$IMG_URL" || die "Fallo en la descarga."; fi
fi
echo; ok "Descargada: ${BOLD}$(du -h "$IMG_XZ" | cut -f1)${N} ${DIM}${IMG_NAME}${N}"
sleep 1

#==============================================================================
# PASO 5 · Verificar SHA-256
#==============================================================================
hdr 5 "Verificación de integridad (SHA-256)"
if [[ -z "$SHA_CMD" ]]; then
  warn "Sin sha256sum/shasum; omito la verificación."; sleep 1
else
  $SHA_CMD "$IMG_XZ" | awk '{print $1}' > /tmp/localhash.$$ & spin_wait $! "Calculando hash local del fichero…"
  LOCAL_HASH="$(cat /tmp/localhash.$$)"; rm -f /tmp/localhash.$$
  ok "Local:  ${DIM}${LOCAL_HASH}${N}"
  EXPECTED=""
  if [[ "$SHA_KIND" == "sums" ]]; then
    EXPECTED="$(fetch "$SHA_URL" 2>/dev/null | awk -v f="$IMG_NAME" '$2==f || $2=="*"f {print $1; exit}')"
  elif [[ "$SHA_KIND" == "single" ]]; then
    EXPECTED="$(fetch "$SHA_URL" 2>/dev/null | awk '{print $1}' | head -1)"
  fi
  if [[ -n "$EXPECTED" ]]; then
    info "Oficial: ${DIM}${EXPECTED}${N}"
    if [[ "${LOCAL_HASH,,}" == "${EXPECTED,,}" ]]; then
      echo; ok "${G}${BOLD}INTEGRIDAD VERIFICADA${N} — la descarga coincide con el original."
    else
      echo; err "¡EL HASH NO COINCIDE! La descarga puede estar corrupta o manipulada."
      read -rp "   ¿Continuar de todos modos? [s/N] › " c; [[ "${c,,}" == "s" ]] || die "Abortado por seguridad."
    fi
  else
    warn "No pude obtener el hash oficial automáticamente."
    read -rp "   Pega el SHA-256 esperado (Enter para omitir) › " EXP2
    if [[ -n "$EXP2" ]]; then
      [[ "${LOCAL_HASH,,}" == "${EXP2,,}" ]] && ok "Verificado (manual)." || {
        err "No coincide."; read -rp "   ¿Continuar? [s/N] › " c; [[ "${c,,}" == "s" ]] || die "Abortado."; }
    fi
  fi
  sleep 1
fi

#==============================================================================
# PASO 6 · Descomprimir
#==============================================================================
hdr 6 "Descomprimiendo la imagen"
IMG="${IMG_XZ%.xz}"
if [[ -f "$IMG" ]]; then
  info "Ya existe descomprimida ($(du -h "$IMG" | cut -f1))."
  read -rp "   ¿Rehacer descompresión? [s/N] › " r; [[ "${r,,}" == "s" ]] && rm -f "$IMG"
fi
if [[ ! -f "$IMG" ]]; then
  xz -dkc "$IMG_XZ" > "$IMG" & xzpid=$!
  while kill -0 "$xzpid" 2>/dev/null; do
    printf "\r   ${C}◉${N} Descomprimiendo… ${BOLD}%s${N}   " "$(du -h "$IMG" 2>/dev/null | cut -f1)"
    sleep 0.4
  done
  wait "$xzpid" || { rm -f "$IMG"; die "Fallo al descomprimir."; }
  printf "\r\033[K"
fi
ok "Imagen lista para hornear: ${BOLD}$(du -h "$IMG" | cut -f1)${N}"
sleep 1

#==============================================================================
# PASO 7 · Datos del laboratorio (auto-conectado)
#==============================================================================
hdr 7 "Datos del laboratorio · WiFi + clave SSH"
# Autodetección de la WiFi a la que ESTE portátil está conectado ahora.
DET_SSID=""; DET_PSK=""
ACT_UUID="$(nmcli -t -f UUID,TYPE connection show --active 2>/dev/null | awk -F: '$2 ~ /wireless/{print $1; exit}')"
if [[ -n "$ACT_UUID" ]]; then
  DET_SSID="$(nmcli -t -s -g 802-11-wireless.ssid connection show "$ACT_UUID" 2>/dev/null)"
  [[ -z "$DET_SSID" ]] && DET_SSID="$(iwgetid -r 2>/dev/null)"
  DET_PSK="$($SUDO nmcli -s -g 802-11-wireless-security.psk connection show "$ACT_UUID" 2>/dev/null)"
fi
if [[ -n "$DET_SSID" ]]; then
  info "WiFi actual detectada: ${BOLD}${DET_SSID}${N}$([[ -n "$DET_PSK" ]] && echo "  ${G}(contraseña recuperada ✓)${N}")"
  read -rp "   SSID [${DET_SSID}] › " SSID; SSID="${SSID:-$DET_SSID}"
  if [[ -n "$DET_PSK" ]]; then
    read -rsp "   Contraseña WiFi [Enter = la detectada] › " PSK; echo; PSK="${PSK:-$DET_PSK}"
  else
    warn "No pude recuperar la contraseña automáticamente; tecléala:"
    read -rsp "   Contraseña del WiFi (WPA2) › " PSK; echo
  fi
else
  read -rp "   SSID de tu WiFi local › " SSID
  read -rsp "   Contraseña del WiFi (WPA2) › " PSK; echo
fi
[[ -z "$SSID" ]] && die "El SSID es obligatorio."
[[ -z "$PSK" ]] && die "La contraseña del WiFi es obligatoria."
case "$SSID$PSK" in
  *"'"*) die "Evita comillas simples ' en SSID/contraseña (rompe el horneado)." ;;
  *'"'*) die "Evita comillas dobles en SSID/contraseña (rompe wpa_supplicant de Kali)." ;;
  *'\'*) die "Evita la barra invertida \\ en SSID/contraseña (rompe la config WiFi)." ;;
esac

echo
DEF_HOST="pineapple-lab"; DEF_USER=$([[ "$DISTRO" == "kali" ]] && echo "kali" || echo "pi")
read -rp "   Hostname [${DEF_HOST}] › " HOSTN; HOSTN="${HOSTN:-$DEF_HOST}"
read -rp "   Usuario [${DEF_USER}] › " PIUSER; PIUSER="${PIUSER:-$DEF_USER}"
read -rsp "   Contraseña de consola [pineapple] › " PIPASS; echo; PIPASS="${PIPASS:-pineapple}"
COUNTRY="ES"

if [[ ! -f "$KEY.pub" ]]; then
  info "Genero clave SSH dedicada del lab (ed25519)..."
  mkdir -p "$HOME/.ssh"; ssh-keygen -t ed25519 -N "" -f "$KEY" -C "pi-pineapple-lab" >/dev/null
  ok "Clave creada: ${BOLD}$KEY${N}"
else
  ok "Reutilizo la clave del lab: ${BOLD}$KEY${N}"
fi
PUBKEY="$(cat "$KEY.pub")"
PWHASH="$(openssl passwd -6 "$PIPASS")"
sleep 1

#==============================================================================
# PASO 8 · Hornear la personalización dentro de la imagen
#==============================================================================
hdr 8 "Horneando el auto-conectado (${DISTRO})"
LOOP="$($SUDO losetup -fP --show "$IMG")" || die "losetup falló."
$SUDO partprobe "$LOOP" 2>/dev/null || true; udevadm settle 2>/dev/null || sleep 1
BOOT_MNT="$(mktemp -d)"; ROOT_MNT="$(mktemp -d)"
cleanup_bake(){
  $SUDO umount "$BOOT_MNT" 2>/dev/null || true
  $SUDO umount "$ROOT_MNT" 2>/dev/null || true
  $SUDO losetup -d "$LOOP" 2>/dev/null || true
  rmdir "$BOOT_MNT" "$ROOT_MNT" 2>/dev/null || true
}
trap cleanup_bake EXIT
BOOTP="${LOOP}p1"; ROOTP="${LOOP}p2"
$SUDO mount "$BOOTP" "$BOOT_MNT" 2>/dev/null || die "No pude montar la partición boot ($BOOTP)."
ok "Partición boot montada."

bake_rpios(){
  [[ -f "$BOOT_MNT/cmdline.txt" ]] || die "No hay cmdline.txt: ¿seguro que es Raspberry Pi OS?"
  cat > /tmp/firstrun.sh <<EOF
#!/bin/bash
set +e
SYSMODS=/usr/lib/raspberrypi-sys-mods/imager_custom
if [ -f "\$SYSMODS" ]; then \$SYSMODS set_hostname '${HOSTN}'; else
  echo '${HOSTN}' >/etc/hostname
  sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTN}/g" /etc/hosts; fi
if [ -f /usr/lib/userconf-pi/userconf ]; then /usr/lib/userconf-pi/userconf '${PIUSER}' '${PWHASH}'; else
  FIRSTUSER=\`getent passwd 1000 | cut -d: -f1\`; echo "\$FIRSTUSER:${PWHASH}" | chpasswd -e; fi
if [ -f "\$SYSMODS" ]; then \$SYSMODS enable_ssh -k '${PUBKEY}'; else
  FHOME=\`getent passwd 1000 | cut -d: -f6\`; FUSER=\`getent passwd 1000 | cut -d: -f1\`
  install -o "\$FUSER" -m 700 -d "\$FHOME/.ssh"; echo '${PUBKEY}' > "\$FHOME/.ssh/authorized_keys"
  chown "\$FUSER" "\$FHOME/.ssh/authorized_keys"; chmod 600 "\$FHOME/.ssh/authorized_keys"; systemctl enable ssh; fi
mkdir -p /etc/ssh/sshd_config.d
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/99-lab.conf
if [ -f "\$SYSMODS" ]; then \$SYSMODS set_wlan '${SSID}' '${PSK}' '${COUNTRY}'; else
  install -d -m 700 /etc/NetworkManager/system-connections
  cat >/etc/NetworkManager/system-connections/preconfigured.nmconnection <<NMEOF
[connection]
id=preconfigured
type=wifi
[wifi]
mode=infrastructure
ssid=${SSID}
[wifi-security]
key-mgmt=wpa-psk
psk=${PSK}
[ipv4]
method=auto
[ipv6]
method=auto
NMEOF
  chmod 600 /etc/NetworkManager/system-connections/preconfigured.nmconnection; fi
raspi-config nonint do_wifi_country '${COUNTRY}' 2>/dev/null || iw reg set '${COUNTRY}' 2>/dev/null || true
[ -x /usr/sbin/avahi-daemon ] || apt-get install -y avahi-daemon >/dev/null 2>&1 || true
sed -i 's/^#\?publish-workstation=.*/publish-workstation=yes/' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
mkdir -p /etc/avahi/services
cat >/etc/avahi/services/pineapple-lab.service <<AVAHI
<?xml version="1.0" standalone='no'?><!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group><name replace-wildcards="yes">Pineapple-Lab en %h</name>
<service><type>_pineapple-lab._tcp</type><port>22</port>
<txt-record>role=pi-pineapple</txt-record><txt-record>user=${PIUSER}</txt-record><txt-record>ready=1</txt-record>
</service></service-group>
AVAHI
systemctl enable avahi-daemon
systemctl reload avahi-daemon 2>/dev/null || true
rm -f /boot/firmware/firstrun.sh
sed -i 's| systemd.run.*||g' /boot/firmware/cmdline.txt
exit 0
EOF
  $SUDO cp /tmp/firstrun.sh "$BOOT_MNT/firstrun.sh"; rm -f /tmp/firstrun.sh
  $SUDO chmod +x "$BOOT_MNT/firstrun.sh"
  if ! grep -q "systemd.run=/boot/firmware/firstrun.sh" "$BOOT_MNT/cmdline.txt"; then
    $SUDO sed -i 's|$| systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target|' "$BOOT_MNT/cmdline.txt"
    $SUDO bash -c "tr -d '\n' < '$BOOT_MNT/cmdline.txt' > '$BOOT_MNT/cmdline.tmp' && mv '$BOOT_MNT/cmdline.tmp' '$BOOT_MNT/cmdline.txt'"
  fi
  $SUDO touch "$BOOT_MNT/ssh"
  ok "Raspberry Pi OS horneado (firstrun.sh + cmdline.txt + ssh)."
}

bake_kali(){
  # WiFi: en Kali la conexión la hace NetworkManager (perfil más abajo). NO horneamos
  # wpa_supplicant.conf en boot: al coexistir, Kali puede marcar wlan0 como 'unmanaged'
  # y el perfil NM se ignora en silencio (dos mecanismos peleándose = no conecta).
  #
  # Regdomain por cmdline.txt: persistente y aplicado por el kernel ANTES de que NM
  # intente conectar. Sin país, el chip arranca en dominio mundial '00', que BLOQUEA
  # casi todo el 5 GHz (y deja wlan0 en rfkill) → no vería un AP de 5 GHz.
  if [[ -f "$BOOT_MNT/cmdline.txt" ]] && ! grep -q 'cfg80211.ieee80211_regdom=' "$BOOT_MNT/cmdline.txt"; then
    $SUDO sed -i "s|\$| cfg80211.ieee80211_regdom=${COUNTRY}|" "$BOOT_MNT/cmdline.txt"
  fi

  # Montar rootfs ext4 (aquí va el grueso: Kali no tiene firstrun.sh).
  $SUDO mount "$ROOTP" "$ROOT_MNT" 2>/dev/null || die "No pude montar el rootfs de Kali ($ROOTP)."
  [[ -d "$ROOT_MNT/etc" ]] || die "El rootfs no tiene /etc: partición inesperada."

  local UHOME="/home/${PIUSER}"; [[ -d "$ROOT_MNT$UHOME" ]] || UHOME="/root"
  $SUDO install -d -m 700 "$ROOT_MNT$UHOME/.ssh"
  echo "$PUBKEY" | $SUDO tee "$ROOT_MNT$UHOME/.ssh/authorized_keys" >/dev/null
  $SUDO chmod 600 "$ROOT_MNT$UHOME/.ssh/authorized_keys"
  local OWN=1000; [[ "$UHOME" == "/root" ]] && OWN=0
  $SUDO chown -R "$OWN:$OWN" "$ROOT_MNT$UHOME/.ssh" 2>/dev/null || true

  # Perfil NetworkManager (lo que de hecho conecta la WiFi en Kali).
  $SUDO install -d -m 700 "$ROOT_MNT/etc/NetworkManager/system-connections"
  cat > /tmp/nm.conn <<NMEOF
[connection]
id=pineapple-lab
type=wifi
autoconnect=true
[wifi]
mode=infrastructure
ssid=${SSID}
[wifi-security]
key-mgmt=wpa-psk
psk=${PSK}
[ipv4]
method=auto
[ipv6]
method=auto
NMEOF
  $SUDO cp /tmp/nm.conn "$ROOT_MNT/etc/NetworkManager/system-connections/pineapple-lab.nmconnection"; rm -f /tmp/nm.conn
  $SUDO chmod 600 "$ROOT_MNT/etc/NetworkManager/system-connections/pineapple-lab.nmconnection"
  $SUDO chown 0:0 "$ROOT_MNT/etc/NetworkManager/system-connections/pineapple-lab.nmconnection"

  # Servicio mDNS (offline).
  $SUDO install -d "$ROOT_MNT/etc/avahi/services"
  cat > /tmp/mdns.xml <<AVAHI
<?xml version="1.0" standalone='no'?><!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group><name replace-wildcards="yes">Pineapple-Lab en %h</name>
<service><type>_pineapple-lab._tcp</type><port>22</port>
<txt-record>role=pi-pineapple</txt-record><txt-record>user=${PIUSER}</txt-record><txt-record>ready=1</txt-record>
</service></service-group>
AVAHI
  $SUDO cp /tmp/mdns.xml "$ROOT_MNT/etc/avahi/services/pineapple-lab.service"; rm -f /tmp/mdns.xml

  $SUDO install -d "$ROOT_MNT/etc/ssh/sshd_config.d"
  printf 'PubkeyAuthentication yes\n' | $SUDO tee "$ROOT_MNT/etc/ssh/sshd_config.d/99-lab.conf" >/dev/null

  # Habilitar SSH al arranque: Kali trae ssh.service DESHABILITADO de fábrica. Sin este
  # symlink no hay puerto 22 aunque la clave y la red estén perfectas. Se hace offline
  # (independiente de la red); el firstboot lo refuerza con 'systemctl enable' en runtime.
  $SUDO install -d "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"
  for u in usr/lib/systemd/system/ssh.service lib/systemd/system/ssh.service; do
    if [[ -f "$ROOT_MNT/$u" ]]; then
      $SUDO ln -sf "/$u" "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/ssh.service"
      break
    fi
  done

  # Firstboot: hostname + contraseña (Kali los resetea, hay que hacerlo en runtime)
  # y asegurar avahi; luego se autodesactiva.
  cat > /tmp/firstboot.sh <<FBEOF
#!/bin/bash
set +e
# --- Kali RESETEA hostname y contraseña por defecto en SU primer arranque, así que
#     estos cambios hay que hacerlos en runtime (aquí), no offline sobre la imagen. ---
hostnamectl set-hostname '${HOSTN}' 2>/dev/null || echo '${HOSTN}' >/etc/hostname
sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTN}/g" /etc/hosts 2>/dev/null
echo '${PIUSER}:${PWHASH}' | chpasswd -e 2>/dev/null
# WiFi: desbloquea rfkill y fija el país para efecto inmediato (el cmdline ya lo
# persiste, pero por si la primera asociación de NM ocurre antes del reboot).
rfkill unblock wifi 2>/dev/null
iw reg set '${COUNTRY}' 2>/dev/null
# SSH: red de seguridad al symlink offline (por si la imagen usa ssh.socket).
systemctl enable --now ssh 2>/dev/null || systemctl enable --now ssh.socket 2>/dev/null
FBEOF
  cat >> /tmp/firstboot.sh <<'FBEOF'
if ! command -v avahi-daemon >/dev/null 2>&1; then
  apt-get update -o Acquire::Retries=3 >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y avahi-daemon avahi-utils >/dev/null 2>&1
fi
sed -i 's/^#\?publish-workstation=.*/publish-workstation=yes/' /etc/avahi/avahi-daemon.conf 2>/dev/null
systemctl enable --now avahi-daemon 2>/dev/null
systemctl reload avahi-daemon 2>/dev/null
systemctl disable pi-pineapple-firstboot.service 2>/dev/null
rm -f /etc/systemd/system/pi-pineapple-firstboot.service
rm -f /etc/systemd/system/multi-user.target.wants/pi-pineapple-firstboot.service
rm -f /usr/local/sbin/pi-pineapple-firstboot.sh
exit 0
FBEOF
  $SUDO install -D -m 755 /tmp/firstboot.sh "$ROOT_MNT/usr/local/sbin/pi-pineapple-firstboot.sh"; rm -f /tmp/firstboot.sh
  cat > /tmp/firstboot.service <<'UNITEOF'
[Unit]
Description=Pi-Pineapple firstboot (hostname, contraseña, avahi/mDNS)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/sbin/pi-pineapple-firstboot.sh
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pi-pineapple-firstboot.sh
RemainAfterExit=no
[Install]
WantedBy=multi-user.target
UNITEOF
  $SUDO install -D -m 644 /tmp/firstboot.service "$ROOT_MNT/etc/systemd/system/pi-pineapple-firstboot.service"; rm -f /tmp/firstboot.service
  $SUDO install -d "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"
  $SUDO ln -sf ../pi-pineapple-firstboot.service "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/pi-pineapple-firstboot.service"

  ok "Kali horneado (WiFi + clave SSH + mDNS + firstboot). Usuario: ${BOLD}${PIUSER}${N}"
}

if [[ "$DISTRO" == "kali" ]]; then bake_kali; else bake_rpios; fi
sync
cleanup_bake; trap - EXIT
ok "Imagen personalizada y desmontada."
sleep 1

#==============================================================================
# PASO 9 · Tarjeta destino + doble confirmación + grabar
#==============================================================================
hdr 9 "Tarjeta destino · autodetección"
warn "Esto BORRA por completo el disco elegido. Confirma bien tamaño/modelo."
echo

SYS_SRC="$(findmnt -no SOURCE / 2>/dev/null)"; SYS_SRC="${SYS_SRC%%[*}"
SYS_DISK="$(lsblk -nso NAME,TYPE "$SYS_SRC" 2>/dev/null | awk '$2=="disk"{n=$1; gsub(/[^a-zA-Z0-9]/,"",n); print "/dev/"n; exit}')"
[[ -n "$SYS_DISK" ]] && info "Disco de sistema (protegido): ${BOLD}${SYS_DISK}${N}"

# Candidatos = discos extraíbles/hotplug que NO son el de sistema.
list_removables(){
  local d _c; mapfile -t _c < <(lsblk -dpno NAME,RM,HOTPLUG,TYPE 2>/dev/null | awk '$4=="disk" && ($2==1||$3==1){print $1}')
  for d in "${_c[@]}"; do [[ "$d" == "$SYS_DISK" ]] && continue; echo "$d"; done
}
mapfile -t FILT < <(list_removables)

# --- Detección al vuelo: si conectas el lector/microSD AHORA (o ya con el script
#     abierto), lo pillo solo. ---
NEWDEV=""
if ((${#FILT[@]}==0)); then
  warn "No hay ningún disco extraíble conectado todavía."
  info "Conéctalo AHORA (lector microSD / USB) y lo detecto solo…"
  for ((t=1;t<=120;t++)); do
    mapfile -t FILT < <(list_removables)
    ((${#FILT[@]})) && { NEWDEV="${FILT[0]}"; break; }
    printf "\r   ${DIM}esperando a que conectes un USB… (%02ds)${N}" "$t"; sleep 1
  done
  printf "\r\033[K"
  ((${#FILT[@]})) && ok "¡Detectado al vuelo: ${BOLD}${NEWDEV}${N}!"
else
  # ¿Alguno es NUEVO respecto a cuando arrancó el script? = el que acabas de enchufar.
  for d in "${FILT[@]}"; do
    grep -qxF -- "$d" <<<"$DISKS_AT_START" || { NEWDEV="$d"; break; }
  done
fi

# El recién conectado va el primero (será el recomendado).
if [[ -n "$NEWDEV" ]]; then
  reord=("$NEWDEV"); for d in "${FILT[@]}"; do [[ "$d" == "$NEWDEV" ]] || reord+=("$d"); done
  FILT=("${reord[@]}")
fi

echo
SELNUM=""
if ((${#FILT[@]})); then
  echo -e "   ${BOLD}Discos extraíbles detectados:${N}"
  i=1; for d in "${FILT[@]}"; do
    if   [[ "$d" == "$NEWDEV" ]]; then mark="  ${G}(recién conectado ✓)${N}"
    elif ((i==1));                then mark="  ${DIM}(recomendado)${N}"
    else                              mark=""; fi
    echo -e "   ${C}$i)${N} $(lsblk -dno SIZE,MODEL,TRAN "$d" | xargs)  →  ${BOLD}$d${N}${mark}"; ((i++))
  done
  echo
  if ((${#FILT[@]}==1)); then
    ok "Candidato único → ${G}100% seguro${N} en tu caso (único extraíble y NO es el de sistema)."
    read -rp "   Enter=1, o el número › " sel; sel="${sel:-1}"
  else
    warn "Hay más de un disco extraíble: elige con cuidado por tamaño/modelo."
    read -rp "   Número del disco [1-${#FILT[@]}] › " sel
  fi
  if   [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#FILT[@]} )); then DEV="${FILT[$((sel-1))]}"; SELNUM="$sel"
  elif [[ "$sel" == /dev/* ]]; then DEV="$sel"
  else die "Selección no válida: '$sel' (teclea el número de la lista)."
  fi
else
  warn "No detecté discos extraíbles. Lista completa (elige con cuidado):"
  lsblk -dpno NAME,SIZE,MODEL,TRAN,RM | sed 's/^/   /'
  read -rp "   Dispositivo destino (ej. /dev/sda) › " DEV
fi

[[ -b "$DEV" ]] || die "$DEV no es un dispositivo de bloque válido."
# Barrera dura: ni el disco de sistema ni ninguna de sus particiones.
[[ -n "$SYS_DISK" && "$DEV" == "$SYS_DISK"* ]] && die "¡PELIGRO! $DEV es (o pertenece a) tu disco de sistema ${SYS_DISK}. Abortado."
# Barrera secundaria: resuelve el disco físico de / (soporta LUKS/LVM) por si falló la detección anterior.
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null)"; ROOT_SRC="${ROOT_SRC%%[*}"
ROOT_DISK="$(lsblk -nso NAME,TYPE "$ROOT_SRC" 2>/dev/null | awk '$2=="disk"{n=$1; gsub(/[^a-zA-Z0-9]/,"",n); print "/dev/"n; exit}')"
[[ -n "$ROOT_DISK" && "$DEV" == "$ROOT_DISK"* ]] && die "¡PELIGRO! $DEV coincide con el disco de / (${ROOT_DISK}). Abortado."
DEV_SIZE="$(lsblk -dno SIZE "$DEV")"; DEV_MODEL="$(lsblk -dno MODEL "$DEV" | xargs)"; DEV_RM="$(lsblk -dno RM "$DEV")"

echo
echo -e "  ${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo -e "   ${R}${BOLD}CONFIRMACIÓN — se DESTRUIRÁ todo el contenido de ${DEV}${N}"
echo -e "  ${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo -e "   Dispositivo : ${BOLD}${DEV}${N}"
echo -e "   Tamaño      : ${BOLD}${DEV_SIZE}${N}"
echo -e "   Modelo      : ${BOLD}${DEV_MODEL:-desconocido}${N}"
echo -e "   Extraíble   : $([[ "$DEV_RM" == "1" ]] && echo "${G}sí${N}" || echo "${R}NO (¡revisa!)${N}")"
echo
# 1ª confirmación: basta el número del disco (no hay que teclear la ruta).
DEV_NUM="${SELNUM:-}"
if [[ -z "$DEV_NUM" ]]; then
  for i in "${!FILT[@]}"; do [[ "${FILT[$i]}" == "$DEV" ]] && { DEV_NUM=$((i+1)); break; }; done
fi
if [[ -n "$DEV_NUM" ]]; then
  read -rp "   1ª confirmación — teclea el número del disco (${DEV_NUM}) › " c1
  [[ "$c1" == "$DEV_NUM" || "$c1" == "$DEV" ]] || die "No coincide. Abortado (no se ha escrito nada)."
else
  DEV_SHORT="$(basename "$DEV")"
  read -rp "   1ª confirmación — teclea el nombre del disco (${DEV_SHORT}) › " c1
  [[ "$c1" == "$DEV_SHORT" || "$c1" == "$DEV" ]] || die "No coincide. Abortado (no se ha escrito nada)."
fi
read -rp "   2ª confirmación — escribe en mayúsculas CONFIRMAR › " c2
[[ "$c2" == "CONFIRMAR" ]] || die "Cancelado (no se ha escrito nada)."
echo; ok "Confirmado. Grabando..."
echo

for part in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
  $SUDO umount "$part" 2>/dev/null && info "Desmontado $part" || true
done
$SUDO dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress || die "Error durante la escritura."
sync

# Verificación post-dd: releo del disco EXACTAMENTE los bytes de la imagen y comparo
# hash. Una microSD dañada (p.ej. por un brownout) acepta escrituras corruptas EN
# SILENCIO; esto lo caza aquí en vez de a los 6 min viendo que la Pi no arranca.
info "Verificando la escritura (releyendo del disco, puede tardar 1-2 min)..."
IMG_BYTES="$(stat -c%s "$IMG")"
SRC_SUM="$(sha256sum "$IMG" | awk '{print $1}')"
DST_SUM="$($SUDO head -c "$IMG_BYTES" "$DEV" | sha256sum | awk '{print $1}')"
if [[ "$SRC_SUM" == "$DST_SUM" ]]; then
  ok "Verificación OK: el disco coincide byte a byte con la imagen."
else
  die "¡Verificación FALLIDA! El disco NO coincide con la imagen (microSD dañada o mala conexión del lector). NO arranques esta tarjeta: prueba con otra microSD."
fi

$SUDO eject "$DEV" 2>/dev/null && EJECTED=1 || EJECTED=0

#==============================================================================
# FIN
#==============================================================================
hdr 9 "¡Hecho!"
ok "Imagen ${BOLD}${DISTRO}${N} grabada en ${BOLD}${DEV}${N} con auto-conectado horneado."
[[ "$EJECTED" == "1" ]] && ok "Disco expulsado: ya puedes sacar la microSD." || info "Grabación completada (sync hecho)."
echo
echo -e "   ${BOLD}Siguiente paso:${N}"
info "1) Mete la microSD en la Pi y dale corriente."
info "2) En este portátil:  ${BOLD}./2-cazar.sh${N}"
info "   Usuario: ${BOLD}${PIUSER}${N} · clave: ${BOLD}${KEY}${N} · hostname: ${BOLD}${HOSTN}${N}"
echo
warn "Recuerda: en redes que filtran mDNS, 2-cazar.sh la encuentra por barrido (normal)."
echo
