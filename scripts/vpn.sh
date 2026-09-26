# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# Linux VPN via wg-easy v15 (SPEC §8).

HV_WG_ADMIN_USER=hvadmin
HV_WG_IPV6_CIDR='fdcc:ad94:bacf:61a4::cafe:0/112'
HV_WG_INIT_ENV=${HV_WG_INIT_ENV:-$HV_ROOT/secrets/wg-easy-init.env}
HV_WG_PASS_FILE=${HV_WG_PASS_FILE:-$HV_ROOT/secrets/wg_easy_admin_password}

vpn_enabled() { [[ ${HV_PLATFORM:-linux} == linux ]] && is_true "${HV_VPN_ENABLED:-true}"; }

# Client AllowedIPs per HV_VPN_LAN_ACCESS (comma separated)
vpn_allowed_ips() {
	if [[ ${HV_VPN_LAN_ACCESS:-host} == full ]]; then
		printf '%s,%s\n' "$HV_VPN_CIDR" "$HV_LAN_CIDR"
	else
		printf '%s,%s/32\n' "$HV_VPN_CIDR" "$HV_LAN_IP"
	fi
}

# vpn_hooks up|down → wg-easy PostUp/PostDown hook string (template vars are wg-easy's)
vpn_hooks() {
	local op=-A
	[[ $1 == down ]] && op=-D
	local s="iptables -t nat $op POSTROUTING -s {{ipv4Cidr}} -o {{device}} -j MASQUERADE; "
	s+="iptables $op INPUT -p udp -m udp --dport {{port}} -j ACCEPT; "
	s+="iptables $op INPUT -i wg0 -p tcp --dport {{uiPort}} -j DROP; "
	s+="iptables $op FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; "
	if [[ ${HV_VPN_LAN_ACCESS:-host} == full ]]; then
		# the whole home LAN, but never the Docker network behind wg-easy (app:80 / panel:8080 would bypass
		# Caddy and could spoof X-Forwarded-For) and no internet exit through the home connection
		s+="iptables $op FORWARD -i wg0 -d ${HV_FRONTEND_SUBNET:-172.31.250.0/24} -j DROP; "
		s+="iptables $op FORWARD -i wg0 -d ${HV_LAN_CIDR} -j ACCEPT; "
	else
		s+="iptables $op FORWARD -i wg0 -d ${HV_LAN_IP}/32 -j ACCEPT; "
	fi
	s+="iptables $op FORWARD -i wg0 -j DROP;"
	printf '%s\n' "$s"
}

# Content of secrets/wg-easy-init.env (password passed as $1)
vpn_render_init_env() {
	local pass=$1
	cat <<EOF
INIT_ENABLED=true
INIT_USERNAME=$HV_WG_ADMIN_USER
INIT_PASSWORD=$pass
INIT_HOST=$WG_HOST
INIT_PORT=$WG_PORT
INIT_DNS=$HV_VPN_DNS
INIT_IPV4_CIDR=$HV_VPN_CIDR
INIT_IPV6_CIDR=$HV_WG_IPV6_CIDR
INIT_ALLOWED_IPS=$(vpn_allowed_ips)
EOF
}

# JSON sent (via stdin) to the node finalize script inside the container
vpn_finalize_payload() {
	local pass=$1 ka=${HV_VPN_KEEPALIVE:-0} ips dns
	local -a a d
	IFS=, read -r -a a <<<"$(vpn_allowed_ips)"
	IFS=, read -r -a d <<<"${HV_VPN_DNS:-}"
	ips=$(json_array "${a[@]}")
	dns=$(json_array "${d[@]}")
	[[ $ka =~ ^[0-9]+$ ]] || ka=0
	printf '{"user":%s,"pass":%s,"postUp":%s,"postDown":%s,"allowedIps":%s,"dns":%s,"keepalive":%d,"host":%s,"port":%d}\n' \
		"$(json_str "$HV_WG_ADMIN_USER")" "$(json_str "$pass")" "$(json_str "$(vpn_hooks up)")" \
		"$(json_str "$(vpn_hooks down)")" "$ips" "$dns" "$ka" "$(json_str "$WG_HOST")" "$WG_PORT"
}

# Fixed node script (no user input in argv; data arrives on stdin)
# shellcheck disable=SC2016
HV_WG_NODE_FINALIZE='
const rd=async()=>{let d="";for await(const c of process.stdin)d+=c;return JSON.parse(d)};
(async()=>{
const i=await rd();
const B="http://127.0.0.1:"+(process.env.PORT||"51821");
const H={"Authorization":"Basic "+Buffer.from(i.user+":"+i.pass).toString("base64"),"Content-Type":"application/json"};
const req=async(m,p,b)=>{const r=await fetch(B+p,{method:m,headers:H,body:b===undefined?undefined:JSON.stringify(b)});
const t=await r.text();if(!r.ok)throw new Error(m+" "+p+" -> HTTP "+r.status+" "+t.slice(0,300));try{return t?JSON.parse(t):null}catch(e){return t}};
const h=await req("GET","/api/admin/hooks");
await req("POST","/api/admin/hooks",{preUp:h.preUp??"",postUp:i.postUp,preDown:h.preDown??"",postDown:i.postDown});
const u=await req("GET","/api/admin/userconfig");
const {id,createdAt,updatedAt,...uc}=u;
Object.assign(uc,{defaultAllowedIps:i.allowedIps,defaultPersistentKeepalive:i.keepalive,host:i.host});
if(i.dns.length)uc.defaultDns=i.dns;
await req("POST","/api/admin/userconfig",uc);
const itf=await req("GET","/api/admin/interface");
if(itf.port!==i.port){const {name,createdAt:a,updatedAt:b2,privateKey,publicKey,...x}=itf;x.port=i.port;
await req("POST","/api/admin/interface",x);
uc.port=i.port;await req("POST","/api/admin/userconfig",uc);}
console.log("OK");
})().catch(e=>{console.error(String(e&&e.message||e));process.exit(1)});'

# shellcheck disable=SC2016
HV_WG_NODE_PING='fetch("http://127.0.0.1:"+(process.env.PORT||"51821")+"/api/information").then(()=>process.exit(0),()=>process.exit(1))'

# shellcheck disable=SC2016
HV_WG_NODE_ADD='
const rd=async()=>{let d="";for await(const c of process.stdin)d+=c;return JSON.parse(d)};
(async()=>{const i=await rd();const B="http://127.0.0.1:"+(process.env.PORT||"51821");
const H={"Authorization":"Basic "+Buffer.from(i.user+":"+i.pass).toString("base64"),"Content-Type":"application/json"};
let r=await fetch(B+"/api/client",{method:"POST",headers:H,body:JSON.stringify({name:i.name,expiresAt:null})});
if(!r.ok)throw new Error("HTTP "+r.status+" "+(await r.text()).slice(0,200));
const j=await r.json();r=await fetch(B+"/api/client/"+j.clientId+"/configuration",{headers:H});
if(!r.ok)throw new Error("HTTP "+r.status);process.stdout.write("#ID "+j.clientId+"\n"+await r.text());
})().catch(e=>{console.error(String(e&&e.message||e));process.exit(1)});'

vpn_admin_password() {
	[[ -f $HV_WG_PASS_FILE ]] || die "未找到 wg-easy 管理员密码文件：$HV_WG_PASS_FILE"
	tr -d '\r\n' <"$HV_WG_PASS_FILE"
}

# Create the one-time INIT env file unless wg-easy was already initialised.
vpn_prepare_init() {
	local pass
	vpn_enabled || return 0
	[[ -n ${WG_HOST:-} && -n ${WG_PORT:-} ]] || die "WG_HOST / WG_PORT 未设置"
	install -d -m 0700 "$HV_ROOT/secrets"
	if [[ ! -f $HV_WG_PASS_FILE ]]; then
		(umask 077 && gen_secret 32 >"$HV_WG_PASS_FILE")
	fi
	if [[ -f $HV_STATE_DIR/wg-easy-finalized ]]; then
		return 0
	fi
	pass=$(vpn_admin_password)
	(umask 077 && vpn_render_init_env "$pass" >"$HV_WG_INIT_ENV")
	chmod 0600 "$HV_WG_INIT_ENV"
}

vpn_wait_api() {
	local timeout=${1:-180} start=$SECONDS
	while ((SECONDS - start < timeout)); do
		if dc exec -T wg-easy node -e "$HV_WG_NODE_PING" >/dev/null 2>&1; then
			return 0
		fi
		sleep 3
	done
	return 1
}

vpn_manual_steps() {
	title "请手动完成 wg-easy 设置（自动配置失败）"
	msg "1. 浏览器打开 https://${HV_HOST}:${HV_ADMIN_PORT} ，用户名 $HV_WG_ADMIN_USER ，密码见文件 $HV_WG_PASS_FILE"
	msg "2. 管理面板 → 配置（Config）："
	msg "   · 允许的 IP（Allowed IPs）：$(vpn_allowed_ips)"
	msg "   · DNS：${HV_VPN_DNS}"
	msg "   · 持久保活（Persistent Keepalive）：${HV_VPN_KEEPALIVE:-0}"
	msg "   · 主机/端口：${WG_HOST} / ${WG_PORT}"
	msg "3. 管理面板 → 钩子（Hooks），整行替换："
	msg "   PostUp:   $(vpn_hooks up)"
	msg "   PostDown: $(vpn_hooks down)"
	msg "4. 保存后执行：sudo $HV_SELF vpn finalize --skip-api"
}

vpn_finalize() {
	local skip_api=${1:-0} pass out
	vpn_enabled || die "VPN 未启用（HV_VPN_ENABLED=false）"
	if ((skip_api == 0)); then
		info "等待 wg-easy 启动…"
		if ! vpn_wait_api 180; then
			warn "wg-easy 接口未响应"
			vpn_manual_steps
			return 1
		fi
		pass=$(vpn_admin_password)
		info "通过 wg-easy API 设置：仅允许访问本机、钩子、默认 DNS/AllowedIPs…"
		if ! out=$(vpn_finalize_payload "$pass" | dc exec -T wg-easy node -e "$HV_WG_NODE_FINALIZE" 2>&1); then
			warn "wg-easy API 调用失败：${out//$pass/***}"
			warn "（若已为 wg-easy 管理员启用两步验证，API 将无法使用，这是正常的）"
			vpn_manual_steps
			return 1
		fi
		ok "wg-easy 已配置"
	fi
	rm -f "$HV_WG_INIT_ENV"
	mkdir -p "$HV_STATE_DIR"
	date -Iseconds >"$HV_STATE_DIR/wg-easy-finalized"
	info "重建 wg-easy 容器（移除初始化变量，应用新钩子）…"
	dc up -d --force-recreate wg-easy >/dev/null
	ok "VPN 初始化完成"
}

vpn_info() {
	title "VPN（wg-easy）"
	msg "管理界面：https://${HV_HOST}:${HV_ADMIN_PORT}"
	msg "用户名：$HV_WG_ADMIN_USER    密码：见 $HV_WG_PASS_FILE（sudo cat 查看）"
	msg "路由器端口转发：仅转发 UDP ${WG_PORT} → ${HV_LAN_IP}:${WG_PORT}（不要转发任何 TCP 端口，不要开 DMZ）"
	msg "客户端 Endpoint：${WG_HOST}:${WG_PORT}    AllowedIPs：$(vpn_allowed_ips)"
	msg "访问范围：$([[ ${HV_VPN_LAN_ACCESS:-host} == full ]] && echo '整个局域网' || echo '仅本机（HomeVault）')"
	warn "强烈建议：登录 wg-easy 后在右上角「账户」中为管理员启用两步验证（启用后本工具的 vpn add 将无法使用 API，请在网页中添加设备）。"
	msg "添加手机：在管理界面点击「新建客户端」，用 WireGuard / WG Tunnel 扫描二维码；或运行 $HV_SELF vpn add <设备名>"
}

vpn_add() {
	local name=$1 pass out id dir
	[[ $name =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "设备名只能包含字母、数字、. _ -（最长 32）"
	pass=$(vpn_admin_password)
	out=$(printf '{"user":%s,"pass":%s,"name":%s}' "$(json_str "$HV_WG_ADMIN_USER")" "$(json_str "$pass")" "$(json_str "$name")" |
		dc exec -T wg-easy node -e "$HV_WG_NODE_ADD" 2>&1) || die "创建失败：${out//$pass/***}（若已启用两步验证，请在网页中添加）"
	id=$(sed -n '1s/^#ID //p' <<<"$out")
	dir=$HV_ROOT/clients
	install -d -m 0700 "$dir"
	(umask 077 && sed '1d' <<<"$out" >"$dir/$name.conf")
	ok "已创建设备「$name」（ID $id），配置文件：$dir/$name.conf"
	if [[ -t 1 ]]; then
		dc exec wg-easy cli clients:qr "$id" || true
	else
		msg "显示二维码：$HV_SELF vpn qr $id"
	fi
	warn "配置文件含私钥：导入手机后请删除 $dir/$name.conf"
}

cmd_vpn() {
	local sub=${1:-info}
	(($#)) && shift
	hv_require_env
	case $sub in
	info | status)
		vpn_enabled || die "VPN 未启用"
		vpn_info
		[[ $sub == status ]] && dc ps wg-easy
		;;
	finalize)
		require_root
		local skip=0
		[[ ${1:-} == --skip-api ]] && skip=1
		vpn_finalize "$skip"
		;;
	list) dc exec -T wg-easy cli clients:list ;;
	qr)
		[[ ${1:-} =~ ^[0-9]+$ ]] || die "用法：$HV_SELF vpn qr <客户端ID>（ID 见 vpn list）"
		dc exec wg-easy cli clients:qr "$1"
		;;
	add)
		require_root
		vpn_add "${1:?用法：$HV_SELF vpn add <设备名>}"
		;;
	reset-password)
		require_root
		local p
		p=$(gen_secret 32)
		dc exec -T wg-easy cli db:admin:reset --password "$p" >/dev/null || die "重置失败"
		(umask 077 && printf '%s\n' "$p" >"$HV_WG_PASS_FILE")
		ok "wg-easy 管理员密码已重置（两步验证也已清除），新密码见 $HV_WG_PASS_FILE"
		;;
	-h | --help | help) help_cmd vpn ;;
	*) die "未知子命令：vpn $sub（可用：info status finalize list qr add reset-password）" ;;
	esac
}
