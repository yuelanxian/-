# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# Host firewall (SPEC §3.4): DOCKER-USER → HOMEVAULT chain; optional ufw (SSH from LAN only).

HV_FW_CHAIN=HOMEVAULT

# TCP ports published by caddy (HTTP/HTTPS/admin/panel), de-duplicated
fw_ports() {
	local -A seen=()
	local p
	for p in "${HV_HTTP_PORT:-80}" "${HV_HTTPS_PORT:-443}" "${HV_ADMIN_PORT:-8443}" "${HV_PANEL_PORT:-9443}"; do
		[[ $p =~ ^[0-9]+$ && -z ${seen[$p]:-} ]] || continue
		seen[$p]=1
		printf '%s\n' "$p"
	done
}

# fw_rules → the iptables arguments (one rule per line, for "-A HOMEVAULT …") — pure, unit-tested
fw_rules() {
	local c p
	# replies and non-new traffic are never touched
	printf '%s\n' "-m conntrack ! --ctstate NEW -j RETURN"
	while IFS= read -r c; do
		[[ -n $c ]] && printf '%s\n' "-s $c -j RETURN"
	done < <(expand_allowed_cidrs "${HV_ALLOWED_CIDRS:-private_ranges 100.64.0.0/10}")
	while IFS= read -r p; do
		printf '%s\n' "-p tcp -m conntrack --ctorigdstport $p -j DROP"
	done < <(fw_ports)
	printf '%s\n' "-j RETURN"
}

fw_have_docker_user() { iptables -w -n -L DOCKER-USER >/dev/null 2>&1; }

fw_apply() {
	local rule
	local -a r
	have iptables || die "未找到 iptables"
	fw_have_docker_user || die "未找到 DOCKER-USER 链：Docker 可能未运行，或使用了 nftables 防火墙后端（本工具仅支持 iptables 后端）"
	iptables -w -N "$HV_FW_CHAIN" 2>/dev/null || true
	iptables -w -F "$HV_FW_CHAIN"
	while IFS= read -r rule; do
		read -r -a r <<<"$rule"
		iptables -w -A "$HV_FW_CHAIN" "${r[@]}"
	done < <(fw_rules)
	# exactly one jump, at the top of DOCKER-USER
	while iptables -w -D DOCKER-USER -j "$HV_FW_CHAIN" 2>/dev/null; do :; done
	iptables -w -I DOCKER-USER 1 -j "$HV_FW_CHAIN"
	ok "防火墙规则已应用：外部（非 ${HV_ALLOWED_CIDRS}）来源访问 TCP $(fw_ports | paste -sd, -) 的新连接将被丢弃"
}

fw_remove() {
	have iptables || return 0
	while iptables -w -D DOCKER-USER -j "$HV_FW_CHAIN" 2>/dev/null; do :; done
	iptables -w -F "$HV_FW_CHAIN" 2>/dev/null || true
	iptables -w -X "$HV_FW_CHAIN" 2>/dev/null || true
	ok "已移除 HomeVault 防火墙规则"
}

fw_is_applied() {
	have iptables || return 1
	iptables -w -C DOCKER-USER -j "$HV_FW_CHAIN" >/dev/null 2>&1 &&
		iptables -w -S "$HV_FW_CHAIN" 2>/dev/null | grep -q -- '-j DROP'
}

fw_show() {
	if ! have iptables; then
		warn "未找到 iptables"
		return 0
	fi
	if fw_is_applied; then ok "HOMEVAULT 链已生效"; else warn "HOMEVAULT 链未生效（运行：sudo $HV_SELF firewall --apply）"; fi
	iptables -w -S DOCKER-USER 2>/dev/null || true
	iptables -w -S "$HV_FW_CHAIN" 2>/dev/null || true
	if systemd_available; then
		msg "开机自动应用（homevault-firewall.service）：$(systemctl is-enabled homevault-firewall.service 2>/dev/null || echo 未安装)"
	fi
	if have ufw; then
		msg "ufw 状态："
		ufw status verbose 2>/dev/null | head -n 20 || true
	fi
}

fw_setup_ufw() {
	local ssh_port=${1:-22}
	have ufw || return 0
	[[ -n ${HV_LAN_CIDR:-} ]] || {
		warn "HV_LAN_CIDR 未设置，跳过 ufw 配置"
		return 0
	}
	if ! confirm "检测到 ufw：设置为默认拒绝入站，仅允许局域网 $HV_LAN_CIDR 访问 SSH（端口 $ssh_port）？" y; then
		return 0
	fi
	ufw default deny incoming >/dev/null
	ufw default allow outgoing >/dev/null
	ufw allow from "$HV_LAN_CIDR" to any port "$ssh_port" proto tcp comment 'HomeVault: SSH from LAN' >/dev/null
	ufw --force enable >/dev/null
	ok "ufw 已启用：仅局域网可 SSH（Docker 发布的端口不经过 ufw，由 HOMEVAULT 链保护）"
}

cmd_firewall() {
	local action=show ssh_port=22 no_ufw=0
	while (($#)); do
		case $1 in
		--apply) action=apply ;;
		--show) action=show ;;
		--remove) action=remove ;;
		--ssh-port)
			ssh_port=${2:?}
			shift
			;;
		--no-ufw) no_ufw=1 ;;
		-h | --help)
			help_cmd firewall
			return 0
			;;
		*) die "未知参数：$1" ;;
		esac
		shift
	done
	hv_require_env
	case $action in
	show)
		[[ $(id -u) -eq 0 ]] || warn "非 root 用户可能无法读取 iptables 规则"
		fw_show
		;;
	apply)
		require_root
		fw_apply
		if systemd_available && [[ ${HV_FW_FROM_SYSTEMD:-0} != 1 ]]; then
			systemd_install_units homevault-firewall.service
			systemctl enable homevault-firewall.service >/dev/null 2>&1 || true
			ok "已设置开机自动应用（homevault-firewall.service）"
		fi
		((no_ufw)) || [[ ${HV_FW_FROM_SYSTEMD:-0} == 1 ]] || fw_setup_ufw "$ssh_port"
		;;
	remove)
		require_root
		fw_remove
		if systemd_available && [[ ${HV_FW_FROM_SYSTEMD:-0} != 1 ]] && [[ -f /etc/systemd/system/homevault-firewall.service ]]; then
			systemctl disable homevault-firewall.service >/dev/null 2>&1 || true
		fi
		;;
	esac
}
