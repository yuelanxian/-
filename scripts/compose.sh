# shellcheck shell=bash disable=SC2034 # globals are shared between the sourced modules
# docker compose invocation helpers and the simple wrapper commands (up/down/…/update/harden).

unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_ENV_FILES

# Profiles for this installation (one per line).
hv_profiles() {
	if [[ $HV_PLATFORM == linux ]] && is_true "$HV_VPN_ENABLED"; then printf '%s\n' vpn; fi
	if is_true "$HV_DDNS_ENABLED"; then printf '%s\n' ddns; fi
	if is_true "$HV_MONITOR_ENABLED"; then printf '%s\n' monitor; fi
	return 0
}

# Fill the named array with the global compose arguments (files, env file, project, profiles).
hv_compose_args() {
	local -n _out=$1
	local p
	_out=(-f "$HV_ROOT/compose.yaml")
	[[ $HV_TLS_MODE == acme-dns && -f $HV_ROOT/compose.acme.yaml ]] && _out+=(-f "$HV_ROOT/compose.acme.yaml")
	[[ -f $HV_ROOT/compose.storage.yaml ]] && _out+=(-f "$HV_ROOT/compose.storage.yaml")
	_out+=(--project-directory "$HV_ROOT" --env-file "$HV_ENV_FILE" -p "$COMPOSE_PROJECT_NAME")
	while IFS= read -r p; do
		[[ -n $p ]] && _out+=(--profile "$p")
	done < <(hv_profiles)
	return 0
}

dc() {
	local -a a
	hv_compose_args a
	docker compose "${a[@]}" "$@"
}

# exec in a service; -T unless we have a terminal on both ends
dc_exec() {
	local svc=$1
	shift
	if [[ -t 0 && -t 1 ]]; then
		dc exec "$svc" "$@"
	else
		dc exec -T "$svc" "$@"
	fi
}

# occ as www-data (never with a TTY when output is captured)
occ() { dc exec -T -u www-data app php occ "$@"; }
occ_tty() {
	if [[ -t 0 && -t 1 ]]; then dc exec -u www-data app php occ "$@"; else occ "$@"; fi
}

# Container id of a service ('' when not created)
dc_cid() {
	{ dc ps -q "$1" 2>/dev/null || true; } | head -n1
}

# running|healthy|unhealthy|starting|exited|missing
dc_state() {
	local cid st health
	cid=$(dc_cid "$1")
	[[ -n $cid ]] || {
		echo missing
		return 0
	}
	st=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null) || {
		echo missing
		return 0
	}
	if [[ $st == running ]]; then
		health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null || true)
		[[ -n $health ]] && st=$health
	fi
	echo "$st"
}

# Nextcloud installed? (occ status --output=json contains "installed":true)
nc_installed() {
	local out
	out=$(occ status --output=json 2>/dev/null) || return 1
	[[ $out == *'"installed":true'* ]]
}

# wait_app_ready [timeout_seconds] — app container healthy/running and NC installed
wait_app_ready() {
	local timeout=${1:-900} start st
	start=$SECONDS
	info "等待 Nextcloud 就绪（首次安装可能需要几分钟）…"
	while ((SECONDS - start < timeout)); do
		st=$(dc_state app)
		case $st in
		healthy | running)
			if nc_installed; then
				ok "Nextcloud 已就绪"
				return 0
			fi
			;;
		exited | dead | missing)
			err "app 容器状态：$st"
			dc logs --tail 80 app >&2 || true
			return 1
			;;
		esac
		sleep 5
	done
	err "等待 Nextcloud 超时（${timeout} 秒）。查看日志：$HV_SELF logs app"
	return 1
}

# wait_service_state svc timeout — until healthy (or running when no healthcheck)
wait_service() {
	local svc=$1 timeout=${2:-120} start st
	start=$SECONDS
	while ((SECONDS - start < timeout)); do
		st=$(dc_state "$svc")
		[[ $st == healthy || $st == running ]] && return 0
		sleep 3
	done
	return 1
}

stack_running() { [[ -n $(dc_cid app) && $(dc_state app) != exited ]]; }

# ---------------------------------------------------------------------------
# Management panel image (built locally from panel/, never pulled — SPEC §15)
# ---------------------------------------------------------------------------
# Hash of everything that goes into the panel image (sources + image name + registry prefix)
panel_src_hash() {
	local d=$HV_ROOT/panel
	[[ -f $d/Dockerfile ]] || return 1
	{
		printf '%s\n%s\n' "${PANEL_IMAGE:-homevault/panel:1.0.0}" "${HV_MIRROR_HUB:-}"
		(cd "$d" && find Dockerfile go.mod cmd internal web -type f ! -name '*_test.go' -print0 2>/dev/null |
			LC_ALL=C sort -z | xargs -0 -r sha256sum)
	} | sha256sum | cut -c1-64
}

# panel_build_if_needed [force] — docker compose build panel when the image is missing or panel/ changed
panel_build_if_needed() {
	local force=${1:-0} img want have=''
	compose_services | grep -qx panel || return 0
	img=${PANEL_IMAGE:-homevault/panel:1.0.0}
	want=$(panel_src_hash) || return 0
	[[ -f $HV_STATE_DIR/panel-build.sha ]] && have=$(<"$HV_STATE_DIR/panel-build.sha")
	if ((force == 0)) && [[ $want == "$have" ]] && docker image inspect "$img" >/dev/null 2>&1; then
		return 0
	fi
	info "构建管理面板镜像 $img（在本机构建，首次约需 1–2 分钟）…"
	if dc build panel; then
		mkdir -p "$HV_STATE_DIR"
		printf '%s\n' "$want" >"$HV_STATE_DIR/panel-build.sha"
		ok "管理面板镜像已就绪"
		return 0
	fi
	if docker image inspect "$img" >/dev/null 2>&1; then
		warn "管理面板镜像构建失败，继续使用已有的 $img（稍后可运行：$HV_SELF compose build panel）"
		return 0
	fi
	err "管理面板镜像构建失败（需要下载 golang 基础镜像；中国大陆请使用 install --mirror daocloud）"
	return 1
}

# The Nextcloud data bind mount is never created automatically (compose: create_host_path: false):
# a missing directory almost always means the data disk is not mounted.
hv_check_nc_data() {
	local p=${HV_NC_DATA_PATH:-}
	[[ $p == /* ]] || return 0
	if [[ ! -d $p ]]; then
		err "Nextcloud 文件目录不存在：$p"
		msg "  数据盘可能没有挂载（检查：lsblk、findmnt、/etc/fstab；挂载：sudo mount -a）。"
		msg "  为了不把照片和文件悄悄写到系统盘，HomeVault 不会自动创建这个目录。挂载后重新运行：sudo $HV_SELF up"
		return 1
	fi
	if [[ -f $HV_STATE_DIR/installed && -z $(find "$p" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
		err "Nextcloud 文件目录是空的：$p（已安装的 Nextcloud 至少有 .ncdata 等文件）"
		msg "  数据盘可能没有挂载到这个目录（检查：findmnt $p、/etc/fstab；挂载：sudo mount -a），挂载后重新运行：sudo $HV_SELF up"
		return 1
	fi
	return 0
}

# A frontend network created by an older compose.yaml (without ip_range) or for another subnet is reused
# as it is by older Compose versions, so a dynamically addressed container could hold Caddy's / the panel's
# fixed address. Remove the stack's containers and networks once (data is kept); `up` recreates them.
hv_migrate_frontend_network() {
	local cfg
	[[ -n ${HV_FRONTEND_IP_RANGE:-} ]] || return 0
	cfg=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{.IPRange}};{{end}}' \
		"${COMPOSE_PROJECT_NAME}_frontend" 2>/dev/null) || return 0
	[[ $cfg == "$HV_FRONTEND_SUBNET $HV_FRONTEND_IP_RANGE;" ]] && return 0
	info "需要重建 Docker 前端网络（Caddy 与管理面板使用固定地址），先停止全部服务（数据不受影响）…"
	dc down --remove-orphans || die "停止服务失败，无法重建 Docker 网络（可手动运行：$HV_SELF down 后再 $HV_SELF up）"
}

# Everything `up` needs before docker compose runs (idempotent; directories only as root)
hv_prepare_up() {
	hv_ensure_env_keys
	hv_validate_env || die ".env 配置有误（见上方说明），请修改 $HV_ENV_FILE 后重试"
	hv_write_derived
	caddy_dns_migrate
	caddy_dns_check || true
	hv_check_nc_data || die "Nextcloud 文件目录不可用，未启动服务"
	storage_render_if_needed
	logs_prepare_dirs
	state_prepare_dirs
	panel_build_if_needed || die "无法构建管理面板镜像"
	hv_migrate_frontend_network
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_up() {
	local recreate=()
	[[ ${1:-} == --force-recreate ]] && recreate=(--force-recreate)
	hv_require_env
	hv_prepare_up
	info "启动服务…"
	dc up -d "${recreate[@]}"
	ok "已启动。状态：$HV_SELF status"
}

cmd_down() {
	hv_require_env
	info "停止并移除容器（数据保留）…"
	dc down --remove-orphans "$@"
}

cmd_restart() {
	hv_require_env
	if (($#)); then dc restart "$@"; else
		hv_prepare_up
		dc up -d
		dc restart
	fi
}

cmd_status() {
	hv_require_env
	dc ps
	if [[ -f $HV_ROOT/state/last-backup-ok ]]; then
		msg "最近一次成功备份：$(cat "$HV_ROOT/state/last-backup-ok")"
	fi
	msg "访问地址：$HV_OVERWRITE_CLI_URL"
	msg "管理面板：$(hv_panel_url)"
}

cmd_pull() { # [--quiet] [服务…]
	hv_require_env
	dc pull --ignore-buildable "$@" || dc pull "$@"
}

cmd_compose() {
	hv_require_env
	dc "$@"
}

cmd_occ() {
	hv_require_env
	occ_tty "$@"
}

cmd_harden() {
	hv_require_env
	local hook=/docker-entrypoint-hooks.d/before-starting/10-homevault.sh
	info "重新执行加固脚本…"
	dc exec -T -u www-data app "$hook" || die "加固脚本执行失败"
	title "关键安全设置"
	msg "双因素认证：$(occ twofactorauth:enforce 2>/dev/null | tr -d '\r')"
	msg "token_auth_enforced：$(occ config:system:get token_auth_enforced 2>/dev/null || echo 未设置)"
	msg "公开分享链接（shareapi_allow_links）：$(occ config:app:get core shareapi_allow_links 2>/dev/null || echo 未设置)"
	msg "审计日志（admin_audit）：$(occ app:list --enabled 2>/dev/null | grep -q -- '- admin_audit:' && echo 已启用 || echo 未启用)"
}

# bump_nc_major IMAGE → same reference with the major version + 1 (e.g. nextcloud:34-apache → 35-apache)
bump_nc_major() {
	local img=$1 repo tag major rest
	repo=${img%:*}
	tag=${img##*:}
	[[ $img == *:* && $repo != "$img" ]] || return 1
	[[ $tag =~ ^([0-9]+)(.*)$ ]] || return 1
	major=${BASH_REMATCH[1]}
	rest=${BASH_REMATCH[2]}
	# 34.0.4-apache → 35-apache (a pinned minor would not exist for the next major)
	[[ $rest =~ ^(\.[0-9]+)+(.*)$ ]] && rest=${BASH_REMATCH[2]}
	printf '%s:%s%s\n' "$repo" $((10#$major + 1)) "$rest"
}

cmd_update() {
	local major=0 skip_backup=0 a new
	while (($#)); do
		case $1 in
		--major) major=1 ;;
		--skip-backup) skip_backup=1 ;;
		-h | --help)
			help_cmd update
			return 0
			;;
		*) die "未知参数：$1" ;;
		esac
		shift
	done
	hv_require_env
	require_root
	if ((skip_backup == 0)); then
		if backup_configured; then
			info "更新前先备份…"
			cmd_backup || die "备份失败，已中止更新（确认无误可加 --skip-backup 跳过）"
		else
			warn "未配置备份，跳过更新前备份"
		fi
	fi
	if ((major)); then
		new=$(bump_nc_major "$NEXTCLOUD_IMAGE") || die "无法识别 NEXTCLOUD_IMAGE 的主版本号：$NEXTCLOUD_IMAGE"
		warn "Nextcloud 主版本升级：$NEXTCLOUD_IMAGE → $new（每次只能升级一个主版本）"
		confirm "确认升级？" n || die "已取消"
		env_set NEXTCLOUD_IMAGE "$new"
	fi
	hv_prepare_up
	info "拉取镜像…"
	cmd_pull --quiet
	if [[ $HV_TLS_MODE == acme-dns ]]; then
		info "重新构建带 DNS 插件的 Caddy…"
		dc build --pull caddy
	fi
	panel_build_if_needed || die "无法构建管理面板镜像"
	dc up -d
	wait_app_ready 3600 || die "升级后 Nextcloud 未就绪，请查看：$HV_SELF logs app"
	occ db:add-missing-indices || warn "db:add-missing-indices 执行失败"
	a=$(occ status 2>/dev/null | tr -d '\r') || true
	msg "$a"
	ok "更新完成"
}

# ensure .env exists and is loaded
hv_require_env() {
	[[ -f $HV_ENV_FILE ]] || die "未找到 $HV_ENV_FILE，请先运行：sudo $HV_SELF install"
	[[ -f $HV_ROOT/compose.yaml ]] || die "未找到 compose.yaml（仓库不完整？）"
}
