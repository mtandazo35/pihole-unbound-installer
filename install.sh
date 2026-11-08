#!/usr/bin/env bash
# pihole-unbound-installer
# Pi-hole v6 + Unbound como resolver recursivo local (DNSSEC) en Debian/Ubuntu.
# Además deja la web del Pi-hole entrando por / (redirige a /admin/).
#
# Uso:
#   bash install.sh               # instala redirección + Unbound
#   bash install.sh --solo-web    # solo la redirección / -> /admin/
#   bash install.sh --solo-unbound
#   bash install.sh --desinstalar # vuelve a los upstreams anteriores y apaga Unbound
#
# Variables opcionales:
#   UNBOUND_PORT=5335    puerto local de Unbound
#   SKIP_PRECHECK=1      no probar el acceso a los root servers (NO recomendado)
#   FORCE_IPV6=yes|no    forzar do-ip6 (por defecto se autodetecta)

set -uo pipefail

UNBOUND_PORT="${UNBOUND_PORT:-5335}"
SKIP_PRECHECK="${SKIP_PRECHECK:-0}"
FORCE_IPV6="${FORCE_IPV6:-}"
BACKUP_DIR="/root/backups"
STATE_DIR="/root/.pihole-unbound-installer"
UNBOUND_CONF="/etc/unbound/unbound.conf.d/pi-hole.conf"
SYSCTL_CONF="/etc/sysctl.d/99-unbound.conf"
WEBROOT="/var/www/html"
STAMP="$(date +%F-%H%M%S)"

C_OK=$'\e[32m'; C_ERR=$'\e[31m'; C_WARN=$'\e[33m'; C_INFO=$'\e[36m'; C_OFF=$'\e[0m'
ok()   { echo "${C_OK}[OK]${C_OFF} $*"; }
info() { echo "${C_INFO}[..]${C_OFF} $*"; }
warn() { echo "${C_WARN}[!!]${C_OFF} $*"; }
die()  { echo "${C_ERR}[ERROR]${C_OFF} $*" >&2; exit 1; }

# ---------------------------------------------------------------- utilidades

ftl_get() { pihole-FTL --config "$1" 2>/dev/null; }
ftl_set() { pihole-FTL --config "$1" "$2" >/dev/null 2>&1; }

# "[ 1.1.1.1, 1.0.0.1 ]" -> ["1.1.1.1","1.0.0.1"]
upstreams_to_json() {
  local raw="$1" out="" item
  local -a items
  raw="$(printf '%s' "$raw" | tr -d '[]')"
  IFS=',' read -ra items <<< "$raw"
  for item in "${items[@]}"; do
    item="$(echo "$item" | xargs)"
    [ -z "$item" ] && continue
    out+="${out:+,}\"$item\""
  done
  echo "[$out]"
}

http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null; }

# ---------------------------------------------------------------- comprobaciones

preflight() {
  [ "$(id -u)" -eq 0 ] || die "Ejecutar como root."
  [ -r /etc/os-release ] || die "No se encuentra /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) : ;;
    *) die "Solo Debian/Ubuntu (detectado: ${PRETTY_NAME:-desconocido})." ;;
  esac
  command -v pihole-FTL >/dev/null || die "Pi-hole no está instalado (falta pihole-FTL)."
  ftl_get dns.upstreams >/dev/null || die "Este Pi-hole no admite 'pihole-FTL --config': hace falta Pi-hole v6."
  systemctl is-active --quiet pihole-FTL || die "pihole-FTL no está activo."
  ok "Pi-hole v6 detectado en ${PRETTY_NAME:-Linux}."
  mkdir -p "$BACKUP_DIR" "$STATE_DIR"
}

need_dig() {
  command -v dig >/dev/null && return 0
  info "Instalando dig (bind9-dnsutils)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q bind9-dnsutils >/dev/null 2>&1 \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y -q dnsutils >/dev/null 2>&1 \
    || die "No se pudo instalar dig."
}

backup() {
  local f="$BACKUP_DIR/pihole-unbound-$1-$STAMP.tar.gz"
  tar czf "$f" --ignore-failed-read \
    /etc/pihole/pihole.toml /etc/resolv.conf /etc/resolvconf.conf \
    /etc/unbound "$WEBROOT/index.html" "$SYSCTL_CONF" 2>/dev/null
  [ -s "$f" ] || die "No se pudo crear el respaldo $f."
  ok "Respaldo: $f"
}

# ---------------------------------------------------------------- web: / -> /admin/

instalar_web() {
  info "Redirección de / a /admin/"
  # En Pi-hole v6 no hay lighttpd: la web la sirve pihole-FTL y, con
  # webserver.serve_all=false, solo entrega lo que hay bajo /admin/.
  # Por eso un index.html en el webroot sigue dando 404.
  local webroot
  webroot="$(ftl_get webserver.paths.webroot)"; webroot="${webroot:-$WEBROOT}"
  mkdir -p "$webroot"
  cat > "$webroot/index.html" << 'EOF'
<!doctype html>
<html lang="es">
  <head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0; url=/admin/">
    <title>Pi-hole</title>
  </head>
  <body></body>
</html>
EOF
  chmod 644 "$webroot/index.html"
  ftl_set webserver.serve_all true || die "No se pudo activar webserver.serve_all."
  sleep 2
  local code; code="$(http_code http://127.0.0.1/)"
  if [ "$code" != "200" ]; then
    info "FTL no tomó el cambio en caliente; reiniciando pihole-FTL..."
    systemctl restart pihole-FTL; sleep 4
    code="$(http_code http://127.0.0.1/)"
  fi
  [ "$code" = "200" ] && ok "Web: / responde 200 y redirige a /admin/." \
                      || warn "Web: / responde $code (revisar webserver.port y webserver.serve_all)."
}

# ---------------------------------------------------------------- Unbound

precheck_root_servers() {
  if [ "$SKIP_PRECHECK" = "1" ]; then warn "Prueba de root servers omitida (SKIP_PRECHECK=1)."; return; fi
  info "Probando acceso directo a los root servers (a.root-servers.net)..."
  local udp tcp ver
  udp="$(dig @198.41.0.4 . NS +norec +time=3 +tries=2 2>/dev/null | grep -m1 ';; flags:')"
  tcp="$(dig @198.41.0.4 . NS +norec +tcp +time=3 +tries=2 2>/dev/null | grep -m1 ';; flags:')"
  ver="$(dig @198.41.0.4 version.bind CH TXT +time=3 +tries=2 +short 2>/dev/null)"
  [[ "$udp" == *" aa"* && "$udp" != *" ra"* ]] \
    || die "UDP/53 a los root servers no es directo (¿DNS interceptado?): '${udp:-sin respuesta}'. Usa SKIP_PRECHECK=1 solo si sabes lo que haces."
  [[ "$tcp" == *" aa"* && "$tcp" != *" ra"* ]] \
    || die "TCP/53 a los root servers falla (típico de CGNAT o firewall): '${tcp:-timeout}'."
  [[ "$ver" == *ATLAS* ]] \
    || die "version.bind devolvió '${ver:-nada}' en vez de \"ATLAS\": hay algo interceptando el DNS."
  ok "Root servers alcanzables por UDP y TCP, sin interceptación."
}

detectar_ipv6() {
  if [ -n "$FORCE_IPV6" ]; then echo "$FORCE_IPV6"; return; fi
  if ip -6 addr show scope global 2>/dev/null | grep -q inet6 \
     && ping -6 -c1 -W2 2001:503:ba3e::2:30 >/dev/null 2>&1; then
    echo yes
  else
    echo no
  fi
}

instalar_unbound() {
  need_dig
  precheck_root_servers

  # Guardar los upstreams actuales para poder volver atrás (solo la primera vez).
  if [ ! -s "$STATE_DIR/upstreams.prev" ]; then
    local prev; prev="$(ftl_get dns.upstreams)"
    if [[ "$prev" != *"127.0.0.1#$UNBOUND_PORT"* ]]; then
      upstreams_to_json "$prev" > "$STATE_DIR/upstreams.prev"
    fi
  fi

  info "Comprobando que apt no vaya a quitar paquetes..."
  apt-get update -qq || warn "apt-get update devolvió error; se continúa con la caché actual."
  if apt-get -s install unbound dns-root-data 2>/dev/null | grep -q '^Remv'; then
    apt-get -s install unbound dns-root-data | grep '^Remv' >&2
    die "Instalar unbound quitaría los paquetes de arriba. Abortado sin cambios."
  fi

  info "Instalando unbound + dns-root-data..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q unbound dns-root-data >/dev/null \
    || die "Falló apt-get install unbound."
  ok "Unbound $(unbound -V 2>/dev/null | awk '/^Version/{print $2}') instalado."

  # Debian 11+: si resolvconf/openresolv está instalado, unbound-resolvconf.service
  # copia los nameservers de /etc/resolv.conf como forwarders y Unbound deja de
  # resolver por sí mismo. Se apaga el servicio; NO se desinstala resolvconf
  # (en imágenes cloud de Debian 13 tocar ese paquete con apt puede arrastrar el kernel).
  systemctl disable --now unbound-resolvconf.service >/dev/null 2>&1 || true
  [ -f /etc/resolvconf.conf ] && sed -Ei 's/^unbound_conf=/#unbound_conf=/' /etc/resolvconf.conf
  rm -f /etc/unbound/unbound.conf.d/resolvconf_resolvers.conf
  ok "unbound-resolvconf desactivado (sin forwarders heredados)."

  # Buffers: so-rcvbuf 1m (config) y so-sndbuf 4m (valor por defecto de unbound >= 1.2x).
  printf 'net.core.rmem_max=1048576\nnet.core.wmem_max=4194304\n' > "$SYSCTL_CONF"
  systemctl restart systemd-sysctl 2>/dev/null || sysctl -p "$SYSCTL_CONF" >/dev/null
  ok "sysctl: rmem_max=$(sysctl -n net.core.rmem_max) wmem_max=$(sysctl -n net.core.wmem_max)"

  local ip6; ip6="$(detectar_ipv6)"
  info "IPv6 hacia internet: $ip6 (do-ip6: $ip6)"

  cat > "$UNBOUND_CONF" << EOF
# Generado por pihole-unbound-installer ($STAMP)
# Basado en https://docs.pi-hole.net/guides/dns/unbound/
server:
    # Sin logfile: va al journal (evita tocar AppArmor). Ver README para activarlo.
    verbosity: 0

    interface: 127.0.0.1
    port: $UNBOUND_PORT
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: $ip6
    prefer-ip6: no

    # root.hints lo trae y actualiza el paquete dns-root-data.

    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 1
    so-rcvbuf: 1m

    # Nunca devolver direcciones privadas para dominios públicos (anti DNS rebinding).
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: fd00::/8
    private-address: fe80::/10
    private-address: 192.0.2.0/24
    private-address: 198.51.100.0/24
    private-address: 203.0.113.0/24
    private-address: 255.255.255.255/32
    private-address: 2001:db8::/32
EOF

  unbound-checkconf >/dev/null || { unbound-checkconf; die "unbound-checkconf falló; Pi-hole no se tocó."; }
  # restart y no 'enable --now': si unbound ya corría, enable --now no recarga la config.
  systemctl enable unbound >/dev/null 2>&1
  systemctl restart unbound || die "Unbound no arrancó: journalctl -u unbound -n 30"
  sleep 2

  local warns
  warns="$(journalctl -u unbound --since "-20s" --no-pager 2>/dev/null | grep -Ei 'warning|error' || true)"
  [ -n "$warns" ] && warn "Avisos de Unbound:" && echo "$warns"

  info "Probando Unbound en 127.0.0.1#$UNBOUND_PORT..."
  local a st ad i
  for i in 1 2 3; do
    a="$(dig +short +time=5 +tries=1 pi-hole.net @127.0.0.1 -p "$UNBOUND_PORT" | grep -Em1 '^[0-9.]+$')"
    [ -n "$a" ] && break; sleep 2
  done
  [ -n "$a" ] || die "Unbound no resuelve pi-hole.net. Pi-hole sigue con sus upstreams anteriores."
  ok "Resuelve: pi-hole.net -> $a"

  for i in 1 2 3; do
    st="$(dig +time=5 +tries=1 fail01.dnssec.works @127.0.0.1 -p "$UNBOUND_PORT" | grep -o 'status: [A-Z]*')"
    [ "$st" = "status: SERVFAIL" ] && break; sleep 2
  done
  [ "$st" = "status: SERVFAIL" ] || die "DNSSEC no valida (fail01.dnssec.works -> ${st:-timeout}). Pi-hole no se tocó."
  ok "DNSSEC: fail01.dnssec.works -> SERVFAIL (firma rota rechazada)."

  ad="$(dig +ad +time=5 dnssec.works @127.0.0.1 -p "$UNBOUND_PORT" | grep -m1 ';; flags:')"
  [[ "$ad" == *" ad"* ]] && ok "DNSSEC: dnssec.works con flag ad." || warn "dnssec.works sin flag ad: '$ad'"

  if command -v unbound-control >/dev/null && [ -n "$(unbound-control list_forwards 2>/dev/null)" ]; then
    warn "Unbound tiene forwarders configurados (no es recursivo puro):"
    unbound-control list_forwards
  fi

  info "Apuntando Pi-hole a 127.0.0.1#$UNBOUND_PORT..."
  ftl_set dns.upstreams "[\"127.0.0.1#$UNBOUND_PORT\"]" || die "No se pudo cambiar dns.upstreams."
  sleep 2
  a="$(dig +short +time=5 example.com @127.0.0.1 | grep -Em1 '^[0-9.]+$')"
  if [ -z "$a" ]; then
    warn "Pi-hole no resuelve a través de Unbound; restaurando upstreams anteriores."
    [ -s "$STATE_DIR/upstreams.prev" ] && ftl_set dns.upstreams "$(cat "$STATE_DIR/upstreams.prev")"
    die "Revertido. Upstreams: $(ftl_get dns.upstreams)"
  fi
  ok "Pi-hole resuelve vía Unbound (example.com -> $a). Upstreams: $(ftl_get dns.upstreams)"

  if [ "$(ftl_get dns.dnssec)" = "true" ]; then
    info "Nota: dns.dnssec está activo en Pi-hole; con Unbound validando no hace falta (doble validación)."
  fi
}

# ---------------------------------------------------------------- desinstalar

desinstalar() {
  backup desinstalar
  local prev='["1.1.1.1","1.0.0.1"]'
  if [ -s "$STATE_DIR/upstreams.prev" ] && [ "$(cat "$STATE_DIR/upstreams.prev")" != "[]" ]; then
    prev="$(cat "$STATE_DIR/upstreams.prev")"
  fi
  ftl_set dns.upstreams "$prev" && ok "Upstreams de Pi-hole: $(ftl_get dns.upstreams)"
  systemctl disable --now unbound >/dev/null 2>&1 && ok "Unbound detenido y deshabilitado."
  rm -f "$UNBOUND_CONF" "$SYSCTL_CONF"
  ok "Listo. El paquete unbound sigue instalado: 'apt remove unbound' si quieres quitarlo."
}

# ---------------------------------------------------------------- main

main() {
  local modo="${1:-todo}"
  echo "== pihole-unbound-installer =="
  preflight
  case "$modo" in
    todo|"")        backup install; instalar_web; instalar_unbound ;;
    --solo-web)     backup web; instalar_web ;;
    --solo-unbound) backup unbound; instalar_unbound ;;
    --desinstalar)  desinstalar; exit 0 ;;
    -h|--help)      sed -n '2,16p' "$0"; exit 0 ;;
    *)              die "Opción desconocida: $modo (usa --help)" ;;
  esac
  echo
  ok "Terminado. Panel: http://$(hostname -I | awk '{print $1}')/  ->  /admin/"
}

main "$@"
