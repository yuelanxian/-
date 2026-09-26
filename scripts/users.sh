# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# Nextcloud user management (occ wrappers) and CA export.

HV_CA_PATH_IN_CONTAINER=/data/caddy/pki/authorities/local/root.crt

# run occ with OC_PASS passed through the environment (never in argv)
occ_with_pass() {
	local pass=$1 cid
	shift
	cid=$(dc_cid app)
	[[ -n $cid ]] || die "app 容器未运行"
	OC_PASS=$pass docker exec -i -e OC_PASS -u www-data "$cid" php occ "$@"
}

valid_uid() { [[ $1 =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]; }

user_add() {
	local name='' admin=0 quota='' display='' pass
	local -a args=()
	while (($#)); do
		case $1 in
		--admin) admin=1 ;;
		--quota) quota=${2:?}; shift ;;
		--display-name) display=${2:?}; shift ;;
		-*) die "未知参数：$1" ;;
		*) name=$1 ;;
		esac
		shift
	done
	[[ -n $name ]] || die "用法：$HV_SELF user add <用户名> [--admin] [--quota 500GB] [--display-name 名字]"
	valid_uid "$name" || die "用户名只能包含字母、数字和 _ . @ -"
	pass=$(gen_secret 20)
	args=(user:add --password-from-env)
	[[ -n $display ]] && args+=(--display-name "$display")
	((admin)) && args+=(--group admin)
	args+=("$name")
	occ_with_pass "$pass" "${args[@]}" || die "创建用户失败"
	if [[ -n $quota ]]; then
		occ user:setting "$name" files quota "$quota" >/dev/null || warn "设置配额失败：$quota"
	fi
	title "新用户（密码只显示这一次，请转交给用户并要求其首次登录后设置两步验证）"
	msg "用户名：$name"
	msg "初始密码：$pass"
	msg "登录地址：$HV_OVERWRITE_CLI_URL"
	msg "手机/电脑客户端请使用「应用密码」：登录网页 → 个人设置 → 安全 → 创建新应用密码"
}

user_reset_password() {
	local name=$1 pass
	valid_uid "$name" || die "用户名格式不正确"
	pass=$(gen_secret 20)
	occ_with_pass "$pass" user:resetpassword --password-from-env "$name" >/dev/null || die "重置密码失败"
	title "已重置密码（只显示这一次）"
	msg "用户名：$name"
	msg "新密码：$pass"
}

user_reset_2fa() {
	local name=$1
	valid_uid "$name" || die "用户名格式不正确"
	occ twofactorauth:disable "$name" totp || die "操作失败"
	ok "已清除 $name 的 TOTP 两步验证；该用户下次登录时需要重新绑定验证器"
}

cmd_user() {
	local sub=${1:-list}
	(($#)) && shift
	hv_require_env
	case $sub in
	add) user_add "$@" ;;
	list) occ user:list "$@" ;;
	reset-2fa) user_reset_2fa "${1:?用法：$HV_SELF user reset-2fa <用户名>}" ;;
	reset-password) user_reset_password "${1:?用法：$HV_SELF user reset-password <用户名>}" ;;
	-h | --help | help) help_cmd user ;;
	*) die "未知子命令：user $sub（可用：add list reset-2fa reset-password）" ;;
	esac
}

# ---------------------------------------------------------------------------
# CA
# ---------------------------------------------------------------------------
# SHA-256 fingerprint (AA:BB:…) of a PEM certificate
cert_fingerprint() {
	local f=$1
	if have openssl; then
		openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
	else
		sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$f" | sed '1d;$d' | base64 -d 2>/dev/null |
			sha256sum | cut -c1-64 | tr 'a-f' 'A-F' | sed 's/../&:/g; s/:$//'
	fi
}

# ca_fetch DEST — copy Caddy's local root CA out of the container (waits up to $2 seconds)
ca_fetch() {
	local dest=$1 timeout=${2:-60} start=$SECONDS tmp
	tmp=$(hv_mktemp)
	while ((SECONDS - start < timeout)); do
		if dc exec -T caddy cat "$HV_CA_PATH_IN_CONTAINER" >"$tmp" 2>/dev/null && grep -q 'BEGIN CERTIFICATE' "$tmp"; then
			install -m 0644 "$tmp" "$dest"
			return 0
		fi
		sleep 2
	done
	return 1
}

ca_instructions() {
	local f=$1
	title "安装根证书（每台访问设备各一次）"
	msg "Android：把 $(basename "$f") 传到手机 → 设置 → 安全（或「安全和隐私 → 更多安全设置」）→ 加密与凭据 → 安装证书 → CA 证书 → 仍然安装。"
	msg "         找不到菜单时在设置里搜索「证书」。Nextcloud 安卓 App 与 Chrome 都信任用户安装的 CA。"
	msg "Windows：双击证书 → 安装证书 → 本地计算机 → 将所有证书放入「受信任的根证书颁发机构」。"
	msg "         或管理员 PowerShell：Import-Certificate -FilePath .\\$(basename "$f") -CertStoreLocation Cert:\\LocalMachine\\Root"
	msg "macOS：  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $(basename "$f")"
	msg "Linux：  sudo cp $(basename "$f") /usr/local/share/ca-certificates/homevault.crt && sudo update-ca-certificates"
	msg "iOS：    用 Safari 打开/隔空投送安装描述文件 → 设置 → 通用 → 关于本机 → 证书信任设置 → 启用完全信任。"
	msg "安装前请核对指纹（SHA-256）与上面显示的一致。"
}

cmd_ca() {
	local export_path='' fp
	while (($#)); do
		case $1 in
		--export) export_path=${2:?}; shift ;;
		-h | --help) help_cmd ca; return 0 ;;
		*) die "未知参数：$1" ;;
		esac
		shift
	done
	hv_require_env
	if [[ $HV_TLS_MODE == acme-dns ]]; then
		ok "域名模式使用公开受信任的证书（Let's Encrypt 等），设备无需安装根证书。"
		return 0
	fi
	[[ -n $export_path ]] || export_path=$HV_ROOT/clients/HomeVault-CA.crt
	install -d -m 0755 "$(dirname "$export_path")"
	ca_fetch "$export_path" 60 || die "无法读取 Caddy 本地 CA（caddy 是否在运行？）"
	fp=$(cert_fingerprint "$export_path")
	ok "根证书已导出：$export_path"
	msg "SHA-256 指纹：$fp"
	ca_instructions "$export_path"
	warn "该根证书可以为任何网站签发证书：私钥保存在 caddy 数据卷（及加密的备份）中，请保护好服务器和备份。"
}
