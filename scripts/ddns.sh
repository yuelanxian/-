# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# DDNS via ddns-go (profile ddns): writes secrets/ddns-go.yaml (format: research/clients.md §6).

HV_DDNS_FILE=${HV_DDNS_FILE:-$HV_ROOT/secrets/ddns-go.yaml}
HV_DDNS_CHECKIP_URLS='https://ddns.oray.com/checkip, https://4.ipw.cn'

# ddns_render_yaml provider id secret domain → ddns-go config
ddns_render_yaml() {
	local provider=$1 id=$2 secret=$3 domain=$4
	cat <<EOF
# 由 hv ddns setup 生成（ddns-go 以 -noweb 运行，不开放网页）
dnsconf:
    - ipv4:
        enable: true
        gettype: url
        url: $HV_DDNS_CHECKIP_URLS
        domains:
            - $(yaml_dq "$domain")
      ipv6:
        enable: false
      dns:
        name: $provider
        id: $(yaml_dq "$id")
        secret: $(yaml_dq "$secret")
      ttl: "600"
notallowwanaccess: true
EOF
}

ddns_valid_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }

ddns_setup() {
	local provider='' id='' secret='' domain='' idlabel seclabel
	while (($#)); do
		case $1 in
		--provider) provider=${2:?}; shift ;;
		--domain) domain=${2:?}; shift ;;
		--id) id=${2:?}; shift ;;
		--secret-file) secret=$(tr -d '\r\n' <"${2:?}"); shift ;;
		*) die "未知参数：$1" ;;
		esac
		shift
	done
	require_root
	[[ -n $provider ]] || provider=$(ask_choice "DNS 服务商" "${HV_DDNS_PROVIDER:-alidns}" alidns tencentcloud dnspod cloudflare huaweicloud)
	[[ $provider =~ ^(alidns|tencentcloud|dnspod|cloudflare|huaweicloud)$ ]] || die "不支持的服务商：$provider"
	[[ -n $domain ]] || domain=$(ask "要自动更新的域名（VPN 连接地址，例如 vpn.example.com）" "${HV_DDNS_DOMAIN:-${WG_HOST:-}}")
	ddns_valid_domain "$domain" || die "域名格式不正确：$domain"
	case $provider in
	alidns) idlabel='AccessKey ID' seclabel='AccessKey Secret' ;;
	tencentcloud) idlabel='SecretId' seclabel='SecretKey' ;;
	dnspod) idlabel='ID' seclabel='Token' ;;
	cloudflare) idlabel='' seclabel='API Token（Edit zone DNS，仅授权该域名）' ;;
	huaweicloud) idlabel='Access Key Id' seclabel='Secret Access Key' ;;
	esac
	if [[ -n $idlabel && -z $id ]]; then id=$(ask "$idlabel" ""); fi
	[[ -n $secret ]] || secret=$(ask_secret "$seclabel（输入时不显示）")
	[[ -n $secret && (-z $idlabel || -n $id) ]] || die "凭据不能为空（非交互模式请用 --id 和 --secret-file）"
	install -d -m 0700 "$HV_ROOT/secrets"
	(umask 077 && ddns_render_yaml "$provider" "$id" "$secret" "$domain" >"$HV_DDNS_FILE")
	chmod 0600 "$HV_DDNS_FILE"
	env_set HV_DDNS_ENABLED true
	env_set HV_DDNS_PROVIDER "$provider"
	env_set HV_DDNS_DOMAIN "$domain"
	if [[ -z ${WG_HOST:-} ]] || is_ipv4 "${WG_HOST:-}"; then
		env_set WG_HOST "$domain"
		warn "WG_HOST 已改为 $domain：已创建的 VPN 客户端需要把 Endpoint 改成该域名（或重新导入）"
	fi
	ok "已写入 $HV_DDNS_FILE"
	msg "建议：为 DNS API 使用只授权该域名的子账号/令牌（阿里云 RAM 子用户、Cloudflare 单 Zone Token）。"
	if [[ -f $HV_ROOT/compose.yaml ]] && [[ -n $(dc_cid app 2>/dev/null) ]]; then
		dc up -d ddns-go && ok "ddns-go 已启动（每 5 分钟检查一次公网 IP）"
	fi
}

ddns_status() {
	local pub resolved
	is_true "${HV_DDNS_ENABLED:-false}" || {
		warn "DDNS 未启用（运行：sudo $HV_SELF ddns setup）"
		return 0
	}
	msg "服务商：${HV_DDNS_PROVIDER}   域名：${HV_DDNS_DOMAIN}"
	msg "容器状态：$(dc_state ddns-go)"
	pub=$(curl -fsS --max-time 8 https://4.ipw.cn 2>/dev/null || curl -fsS --max-time 8 https://ddns.oray.com/checkip 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' || true)
	resolved=$(getent ahostsv4 "$HV_DDNS_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)
	msg "当前公网 IPv4：${pub:-未知}    域名解析：${resolved:-未解析}"
	if [[ -n $pub && -n $resolved && $pub != "$resolved" ]]; then
		warn "域名解析与公网 IP 不一致（可能刚变更，DNS TTL 600 秒内会生效）"
	fi
	if [[ $pub =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
		warn "公网 IP 位于 100.64.0.0/10：运营商级 NAT（没有公网 IP），外网无法连入 VPN，请联系运营商开通公网 IP"
	fi
	dc logs --tail 15 ddns-go 2>/dev/null || true
}

cmd_ddns() {
	local sub=${1:-status}
	(($#)) && shift
	hv_require_env
	case $sub in
	setup) ddns_setup "$@" ;;
	status) ddns_status ;;
	disable)
		require_root
		env_set HV_DDNS_ENABLED false
		dc stop ddns-go >/dev/null 2>&1 || true
		ok "已停用 DDNS"
		;;
	-h | --help | help) help_cmd ddns ;;
	*) die "未知子命令：ddns $sub（可用：setup status disable）" ;;
	esac
}
