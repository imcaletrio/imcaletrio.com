#!/usr/bin/env bash
#===============================================================================
#  2-cazar.sh  ·  Pi-Pineapple · PASO 2: cazar la Pi al primer arranque
#
#  Se queda a la escucha en TU LAN. En cuanto la Pi horneada con 1-instalar.sh
#  arranca y se anuncia por mDNS (_pineapple-lab._tcp), la detecta, espera a que
#  el SSH esté vivo (el 1er boot reinicia una vez), entra con la clave del lab y
#  te copia el arsenal (pineapple-killer.sh).
#
#  Si el mDNS no aparece (p.ej. Kali aún instalando avahi), cae a un barrido de
#  la subred (arp-scan / nmap) probando la clave SSH. Todo en tu red local, sin nube.
#
#  Uso:
#     ./2-cazar.sh                 # caza y abre sesión SSH
#     ./2-cazar.sh --run remote    # caza y ejecuta un bloque (o 'all')
#===============================================================================
set -uo pipefail

G='\033[1;32m'; C='\033[1;36m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1;34m'
DIM='\033[2m'; BOLD='\033[1m'; N='\033[0m'
ok()   { echo -e "  ${G}[✓]${N} $1"; }
info() { echo -e "  ${B}[i]${N} $1"; }
warn() { echo -e "  ${Y}[!]${N} $1"; }
err()  { echo -e "  ${R}[x]${N} $1"; }
need(){ command -v "$1" >/dev/null 2>&1; }

SERVICE="_pineapple-lab._tcp"
KEY="$HOME/.ssh/pi_pineapple_lab"
PIUSER="${PIUSER:-}"                 # env manda; si no, se lee del TXT mDNS; si no, kali
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BLOCK=""; [[ "${1:-}" == "--run" ]] && RUN_BLOCK="${2:-}"

[[ -f "$KEY" ]] || { err "No encuentro la clave del lab ($KEY). Ejecuta antes 1-instalar.sh."; exit 1; }
need avahi-browse || warn "Sin avahi-browse (sudo apt install -y avahi-utils): iré directo al barrido de red."
systemctl is-active --quiet avahi-daemon 2>/dev/null || warn "avahi-daemon inactivo en el portátil (sudo systemctl start avahi-daemon)."

echo -e "${C}== 2-cazar · a la escucha de la Pi en la LAN (${SERVICE}) ==${N}"
info "Esperando a que la Pi arranque y se anuncie... (el 1er boot reinicia una vez)"

IP=""; HOSTN=""; USERFROM=""

#--- 1. Vía mDNS (rápida y limpia) --------------------------------------------
if need avahi-browse; then
  # Muchos APs domésticos filtran el multicast mDNS entre clientes WiFi: si en ~1 min
  # no aparece, casi seguro es eso → saltamos al barrido de red, que sí funciona por unicast.
  for i in $(seq 1 15); do          # ~15 x 4s ≈ 1 min
    line=$(avahi-browse -rtp "$SERVICE" 2>/dev/null | awk -F';' '$1=="=" && $3=="IPv4"{print; exit}')
    if [[ -n "$line" ]]; then
      IP=$(echo "$line" | awk -F';' '{print $8}')
      HOSTN=$(echo "$line" | awk -F';' '{print $7}')
      USERFROM=$(echo "$line" | grep -oE 'user=[A-Za-z0-9_-]+' | head -1 | cut -d= -f2)
      break
    fi
    printf "\r  ${DIM}...escuchando mDNS (%02d/15)${N}" "$i"; sleep 4
  done
  echo
fi

#--- 2. Fallback: barrido de la subred probando la clave SSH ------------------
if [[ -z "$IP" ]]; then
  warn "No apareció por mDNS. Paso al barrido de red (arp-scan/nmap)..."
  # Deducir subred de la interfaz por defecto
  CIDR="$(ip -o -f inet addr show scope global 2>/dev/null | awk '{print $4}' | head -1)"
  [[ -z "$CIDR" ]] && { err "No pude deducir tu subred. Conéctate a tu WiFi/LAN y reintenta."; exit 1; }
  info "Subred: ${BOLD}${CIDR}${N}. Buscando hosts con SSH (puerto 22)..."
  PI_OUI='e4:5f:01|b8:27:eb|dc:a6:32|d8:3a:dd|2c:cf:67'   # OUIs de Raspberry Pi
  HOSTS=""
  if need arp-scan; then
    # arp-scan (capa 2, rápido en /22) da IP<TAB>MAC<TAB>fabricante de los hosts vivos.
    # Ponemos DELANTE los OUI de Raspberry Pi para probar la clave primero contra la Pi.
    SCAN="$(sudo arp-scan --localnet 2>/dev/null \
             | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}[ \t]/{print $1"\t"tolower($2)}' | sort -u)"
    PI_HOSTS="$(printf '%s\n' "$SCAN" | awk -v o="$PI_OUI" '$2 ~ o {print $1}')"
    OTHER_HOSTS="$(printf '%s\n' "$SCAN" | awk -v o="$PI_OUI" '$2 !~ o {print $1}')"
    HOSTS="$(printf '%s\n%s\n' "$PI_HOSTS" "$OTHER_HOSTS" | awk 'NF && !seen[$0]++')"
    [[ -n "$PI_HOSTS" ]] && info "Raspberry Pi por OUI: ${BOLD}$(printf '%s ' $PI_HOSTS)${N}"
  fi
  if [[ -z "$HOSTS" ]] && need nmap; then
    HOSTS="$(nmap -n -p22 --open -oG - "$CIDR" 2>/dev/null | awk '/Ports: 22\/open/{print $2}')"
  fi
  if [[ -z "$HOSTS" ]]; then
    if ! need arp-scan && ! need nmap; then
      err "Para el barrido necesito arp-scan o nmap:  sudo apt install -y arp-scan  (o nmap)."
    else
      err "El barrido no encontró hosts. Revisa que la Pi y el portátil están en la MISMA WiFi y que el AP no tiene 'client isolation'."
    fi
    exit 1
  fi
  CAND="${PIUSER:-kali}"
  for h in $HOSTS; do
    printf "\r  ${DIM}probando %s${N}            " "$h"
    if ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout=4 -o BatchMode=yes "${CAND}@${h}" true 2>/dev/null; then
      IP="$h"; HOSTN="$h"; USERFROM="$CAND"; echo; ok "Pi encontrada por barrido en ${BOLD}$h${N}"; break
    fi
  done
  echo
  [[ -z "$IP" ]] && { err "No hubo respuesta con la clave del lab. La Pi quizá sigue en el 1er boot: espera 1-2 min y reejecuta ./2-cazar.sh"; exit 1; }
fi

PIUSER="${PIUSER:-${USERFROM:-kali}}"
ok "¡Pi detectada!  ${BOLD}${HOSTN:-$IP}${N}  →  ${BOLD}${IP}${N}  (usuario: ${BOLD}${PIUSER}${N})"

#--- 3. Esperar a que SSH acepte ----------------------------------------------
info "Esperando a que SSH responda en ${IP}:22..."
for i in $(seq 1 60); do
  if ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=4 -o BatchMode=yes "${PIUSER}@${IP}" true 2>/dev/null; then ok "SSH vivo."; break; fi
  printf "\r  ${DIM}...SSH aún no (%02d/60)${N}" "$i"; sleep 4
  [[ $i -eq 60 ]] && { echo; err "SSH no respondió. Prueba a mano:  ssh -i $KEY ${PIUSER}@${IP}"; exit 1; }
done
echo

#--- 4. Copiar el arsenal y (opcional) ejecutar un bloque ---------------------
if [[ -f "$SELFDIR/pineapple-killer.sh" ]]; then
  scp -i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -q "$SELFDIR/pineapple-killer.sh" "${PIUSER}@${IP}:~/" \
    && ok "pineapple-killer.sh copiado a la Pi." || warn "No pude copiar el arsenal (sigo)."
else
  warn "pineapple-killer.sh no está junto a este script; no lo copio."
fi

if [[ -n "$RUN_BLOCK" ]]; then
  info "Ejecutando bloque '${RUN_BLOCK}' en la Pi..."
  ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -t "${PIUSER}@${IP}" \
    "chmod +x ~/pineapple-killer.sh && sudo ~/pineapple-killer.sh ${RUN_BLOCK}"
else
  info "Abriendo sesión SSH. Dentro tienes ~/pineapple-killer.sh listo."
  echo -e "     ${DIM}Ideas:  sudo ./pineapple-killer.sh menu   ·   bloque vnc (escritorio móvil)   ·   bloque remote (control a 20 km)${N}"
  echo -e "     ${DIM}Desde el móvil: Termius o Terminus con la misma clave ${KEY}, o RealVNC Viewer tras el bloque vnc.${N}"
  ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -t "${PIUSER}@${IP}"
fi
