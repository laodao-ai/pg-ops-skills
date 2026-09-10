#!/usr/bin/env bash
# pg-sync/scripts/prod/rules-lib.sh —— DATA_RULES 解析 + 策略展开的共用函数，供 00-inventory.sh 与
# 20-dump-data.sh 各自 `source` 使用（20-dump-data 每次都用本文件重新生成计划，不读旧 plan.tsv，
# 避免计划与实际 dump 之间出现窗口期漂移）。本文件不单独执行，随 bundle 一起复制（render.sh bundle
# 对 prod/*.sh 做通配复制，本文件自动包含）。依赖调用方已 source 过 lib.sh（用 psql_ro / die）
# 并已定义 SRC_DB。
#
# 匹配算法说明（不做 pg_dump 通配 → SQL LIKE 的转换 [简化，见 impl 报告]）：DATA_RULES 的表模式字符集
# 已在 parse_data_rules() 里被强校验为 [A-Za-z0-9_.*?]，其中 `*`/`?` 恰好就是 bash 默认（非 extglob）
# 模式匹配的语法，故直接用 bash `[[ x == $pattern ]]` 做匹配：与手写 glob→LIKE 转换器（还要处理 `_`/`%`
# 转义）功能等价、正确性更有保障，且全量表一次性取回后在内存里比对，8000 表规模下开销可忽略。

# ---- 规则解析（DR-01）------------------------------------------------------------------
# parse_data_rules —— 读 $DATA_RULES（字面 \n 分隔的多行文本），校验语法，填充全局数组 RULES，
# 每项格式 "pattern|strategy|arg1|arg2"（arg2 可空）。非法即 die 并指出行号。
declare -a RULES=()
parse_data_rules() {
    local raw="${DATA_RULES:-* full}"
    raw="${raw//\\n/$'\n'}"
    RULES=()
    local lineno=0 line body pat strat a1 a2 extra
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))
        body="${line%%#*}"
        body="$(printf '%s' "${body}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ -z "${body}" ]] && continue
        read -r pat strat a1 a2 extra <<< "${body}"
        [[ -z "${extra}" ]] || die "DATA_RULES 第 ${lineno} 行参数过多：${line}" \
            "每行只能是 <表模式> <策略> [参数…]" "改成正确的参数个数（full/none 无参；sample 一个 K；window 两个：列名 N）"
        [[ -n "${pat}" && "${pat}" =~ ^[A-Za-z0-9_.*?]+$ ]] || die "DATA_RULES 第 ${lineno} 行表模式非法：${pat:-<空>}" \
            "表模式只允许 [A-Za-z0-9_.*?]" "改成合法的 schema.table 通配，如 public.foo_* 或 *"
        case "${strat}" in
            full|none)
                [[ -z "${a1}" ]] || die "DATA_RULES 第 ${lineno} 行：${strat} 不接受参数" \
                    "" "去掉多余的参数" ;;
            sample)
                [[ "${a1}" =~ ^[1-9][0-9]*$ ]] || die "DATA_RULES 第 ${lineno} 行：sample 需要一个正整数 K（当前: ${a1:-<空>}）" \
                    "" "写成 sample 50 这样的形式" ;;
            window)
                [[ "${a1}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "DATA_RULES 第 ${lineno} 行：window 列名非法（当前: ${a1:-<空>}）" \
                    "列名只允许标识符字符" "改成合法的列名"
                [[ "${a2}" =~ ^[0-9]+[dh]$ ]] || die "DATA_RULES 第 ${lineno} 行：window 的 N 只允许 <int>(d|h)（当前: ${a2:-<空>}）" \
                    "分钟单位 m 已删；用小时/天表达" "如 90d 或 12h" ;;
            *)
                die "DATA_RULES 第 ${lineno} 行：未知策略 ${strat:-<空>}" \
                    "策略只允许 full|none|sample|window" "改正策略名" ;;
        esac
        RULES+=("${pat}|${strat}|${a1}|${a2}")
    done <<< "${raw}"
    [[ ${#RULES[@]} -gt 0 ]] || die "DATA_RULES 没有任何有效规则" "全部是空行/注释" "至少留一条兜底规则，如 * full"
}

# pattern_matches <pattern> <schema> <table> —— pattern 无 '.' 时 schema 视为 public
pattern_matches() {
    local pat="$1" sch="$2" tbl="$3" ppat ptbl
    if [[ "${pat}" == *.* ]]; then
        ppat="${pat%%.*}"
        ptbl="${pat#*.}"
    else
        ppat="public"
        ptbl="${pat}"
    fi
    [[ "${sch}" == ${ppat} && "${tbl}" == ${ptbl} ]]
}

# sql_lit <text> —— 转义成 SQL 单引号字符串内部安全的文本（供拼进 '...'::regclass 之类的字面量）
sql_lit() { printf '%s' "${1//\'/\'\'}"; }

# n_to_interval <N>（如 90d / 12h）—— 转成 PostgreSQL interval 字面量内容（如 "90 days"）
n_to_interval() {
    local n="$1" num unit
    num="${n%[dh]}"
    unit="${n: -1}"
    case "${unit}" in
        d) echo "${num} days" ;;
        h) echo "${num} hours" ;;
        *) die "n_to_interval() 收到非法 N: ${n}" ;;
    esac
}

# ---- 取全量候选表（relkind='r'，排除系统 schema）-----------------------------------------
# fetch_all_tables —— 填充全局数组 ALL_TABLES，每项 "schema\ttable\tbytes"
declare -a ALL_TABLES=()
fetch_all_tables() {
    ALL_TABLES=()
    local out
    out="$(psql_ro "${SRC_DB}" -F $'\t' -c "
        select n.nspname, c.relname, pg_total_relation_size(c.oid)
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where c.relkind = 'r'
          and n.nspname not in ('pg_catalog','information_schema')
          and n.nspname !~ '^pg_toast'
          and n.nspname !~ '^pg_temp'
        order by n.nspname, c.relname")"
    [[ -z "${out}" ]] && return 0
    mapfile -t ALL_TABLES <<< "${out}"
}

# count_all_lockable_relkinds —— schema 阶段待锁表数：relkind in ('r','p')，与 10-dump-schema 同口径
count_all_lockable_relkinds() {
    psql_ro "${SRC_DB}" -c "
        select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where c.relkind in ('r','p')
          and n.nspname not in ('pg_catalog','information_schema')
          and n.nspname !~ '^pg_toast'"
}

count_matviews() {
    psql_ro "${SRC_DB}" -c "
        select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where c.relkind = 'm'
          and n.nspname not in ('pg_catalog','information_schema')
          and n.nspname !~ '^pg_toast'"
}

count_large_objects() {
    psql_ro "${SRC_DB}" -c "select count(distinct loid) from pg_largeobject_metadata"
}

# ---- 分区叶子探测（DR-04）----------------------------------------------------------------
# partition_leaf_info <schema> <table> —— 输出 "is_leaf\tpartstrat\tkey_typcat\tbound_kind\tto_literal"
partition_leaf_info() {
    local sch="$1" tbl="$2" sch_l tbl_l
    sch_l="$(sql_lit "${sch}")"; tbl_l="$(sql_lit "${tbl}")"
    psql_ro "${SRC_DB}" -F $'\t' -c "
        SELECT
          coalesce(p.relkind = 'p', false)::text,
          coalesce(pt.partstrat, ''),
          -- partattrs 是 int2vector：与 indkey 一样下标从 0 开始（不是常规数组的 1），[0] 才是第一个分区键列
          coalesce((SELECT ty.typcategory FROM pg_attribute a JOIN pg_type ty ON ty.oid = a.atttypid
                    WHERE a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]), ''),
          CASE WHEN c.relpartbound IS NULL THEN 'none'
               WHEN pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT' THEN 'default'
               WHEN pt.partstrat = 'r' THEN 'range'
               ELSE 'other' END,
          coalesce((regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']*)''\)'))[1], '')
        FROM pg_class c
        LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
        LEFT JOIN pg_class p ON p.oid = i.inhparent
        LEFT JOIN pg_partitioned_table pt ON pt.partrelid = p.oid
        WHERE c.oid = to_regclass(format('%I.%I', '${sch_l}', '${tbl_l}'))"
}

# in_partition_window <to_literal> <interval literal 内容，如 '90 days'> —— 输出 t/f
in_partition_window() {
    local to_lit="$1" interval="$2" to_l int_l
    to_l="$(sql_lit "${to_lit}")"; int_l="$(sql_lit "${interval}")"
    psql_ro "${SRC_DB}" -c "select (('${to_l}')::timestamptz >= now() - interval '${int_l}')::text"
}

# col_attnum <schema> <table> <col> —— 输出 attnum 或空
col_attnum() {
    local sch="$1" tbl="$2" col="$3" sch_l tbl_l col_l
    sch_l="$(sql_lit "${sch}")"; tbl_l="$(sql_lit "${tbl}")"; col_l="$(sql_lit "${col}")"
    psql_ro "${SRC_DB}" -c "
        select a.attnum from pg_attribute a
        where a.attrelid = to_regclass(format('%I.%I','${sch_l}','${tbl_l}'))
          and a.attname = '${col_l}' and a.attnum > 0 and not a.attisdropped"
}

# has_btree_first_index <schema> <table> <attnum> —— 输出 1（有）或空（无）
has_btree_first_index() {
    local sch="$1" tbl="$2" attnum="$3" sch_l tbl_l
    sch_l="$(sql_lit "${sch}")"; tbl_l="$(sql_lit "${tbl}")"
    psql_ro "${SRC_DB}" -c "
        select 1 from pg_index x
        join pg_class ic on ic.oid = x.indexrelid
        join pg_am am on am.oid = ic.relam
        where x.indrelid = to_regclass(format('%I.%I','${sch_l}','${tbl_l}'))
          and am.amname = 'btree'
          and x.indkey[0] = ${attnum}
        limit 1"
}

# ---- 计划行输出（7 列）与已归类标记 --------------------------------------------------------
declare -a PLAN_ROWS=()
declare -A CLASSIFIED=()
plan_row() {
    local sch="$1" tbl="$2" strat="$3" detail="$4" bytes="$5" flag="$6" reason="$7"
    PLAN_ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "${sch}" "${tbl}" "${strat}" "${detail:--}" "${bytes}" "${flag}" "${reason:--}")")
    CLASSIFIED["${sch}.${tbl}"]=1
}

# classify_window <schema> <table> <bytes> <col> <N>（DR-04, DR-05）
classify_window() {
    local sch="$1" tbl="$2" bytes="$3" col="$4" n="$5"
    local info leaf partstrat typcat bound_kind to_lit
    info="$(partition_leaf_info "${sch}" "${tbl}")"
    IFS=$'\t' read -r leaf partstrat typcat bound_kind to_lit <<< "${info}"
    if [[ "${leaf}" == "t" && "${partstrat}" == "r" && "${typcat}" == "D" ]]; then
        if [[ "${bound_kind}" == "default" ]]; then
            plan_row "${sch}" "${tbl}" full partition-window "${bytes}" OK default-partition
            return 0
        elif [[ "${bound_kind}" == "range" && -n "${to_lit}" ]]; then
            local interval inwin
            interval="$(n_to_interval "${n}")"
            inwin="$(in_partition_window "${to_lit}" "${interval}")"
            if [[ "${inwin}" == "t" ]]; then
                plan_row "${sch}" "${tbl}" full partition-window "${bytes}" OK -
            else
                plan_row "${sch}" "${tbl}" none partition-window 0 OK outside-window
            fi
            return 0
        fi
        # 边界值解析失败（罕见）：落到下面的普通表路径当兜底
    fi
    # ---- 普通表路径 ----
    local attnum
    attnum="$(col_attnum "${sch}" "${tbl}" "${col}")"
    [[ -n "${attnum}" ]] || die \
        "DATA_RULES 引用的 window 列不存在：${sch}.${tbl}.${col}" \
        "规则要求该列在表上存在" \
        "改 DATA_RULES：改列名，或用更窄的表模式把这张表交给别的规则处理"
    local hasidx flag reason
    hasidx="$(has_btree_first_index "${sch}" "${tbl}" "${attnum}")"
    if [[ "${hasidx}" != "1" && "${bytes}" -gt "${WINDOW_SEQSCAN_RED:-1073741824}" ]]; then
        flag=RED; reason="no-index-on-${col}"
    else
        flag=OK; reason="-"
    fi
    plan_row "${sch}" "${tbl}" window "col=${col};N=${n}" "${bytes}" "${flag}" "${reason}"
}

# apply_strategy <schema> <table> <bytes> <strategy> <arg1> <arg2> —— sample 展开时把某表交给「下一条规则」的策略
apply_strategy() {
    local sch="$1" tbl="$2" bytes="$3" strat="$4" a1="$5" a2="$6"
    case "${strat}" in
        full) plan_row "${sch}" "${tbl}" full - "${bytes}" OK - ;;
        none) plan_row "${sch}" "${tbl}" none - 0 OK - ;;
        window) classify_window "${sch}" "${tbl}" "${bytes}" "${a1}" "${a2}" ;;
        sample) die "DATA_RULES：sample 的下一条规则不能也是 sample" \
            "sample 展开时把匹配到的表交给下一条规则的策略处理，不支持链式 sample" \
            "把 sample 下一行换成 full/none/window 之一" ;;
    esac
}

# classify_tables —— 主循环：按 RULES 顺序、先匹配先赢，展开 full/none/window/sample，
# 剩余未命中的表落 none reason=no-rule。结果写进 PLAN_ROWS。
classify_tables() {
    PLAN_ROWS=()
    CLASSIFIED=()
    local ridx rule pat strat a1 a2
    for ((ridx = 0; ridx < ${#RULES[@]}; ridx++)); do
        rule="${RULES[${ridx}]}"
        IFS='|' read -r pat strat a1 a2 <<< "${rule}"
        local matches=() row sch tbl bytes key
        for row in "${ALL_TABLES[@]}"; do
            [[ -z "${row}" ]] && continue
            IFS=$'\t' read -r sch tbl bytes <<< "${row}"
            key="${sch}.${tbl}"
            [[ -n "${CLASSIFIED[${key}]:-}" ]] && continue
            pattern_matches "${pat}" "${sch}" "${tbl}" || continue
            matches+=("${row}")
        done
        [[ ${#matches[@]} -eq 0 ]] && continue
        case "${strat}" in
            full)
                for row in "${matches[@]}"; do
                    IFS=$'\t' read -r sch tbl bytes <<< "${row}"
                    plan_row "${sch}" "${tbl}" full - "${bytes}" OK -
                done ;;
            none)
                for row in "${matches[@]}"; do
                    IFS=$'\t' read -r sch tbl bytes <<< "${row}"
                    plan_row "${sch}" "${tbl}" none - 0 OK -
                done ;;
            window)
                for row in "${matches[@]}"; do
                    IFS=$'\t' read -r sch tbl bytes <<< "${row}"
                    classify_window "${sch}" "${tbl}" "${bytes}" "${a1}" "${a2}"
                done ;;
            sample)
                local kk="${a1}" next_rule next_strat next_a1 next_a2
                next_rule="${RULES[$((ridx + 1))]:-}"
                [[ -n "${next_rule}" ]] || die \
                    "DATA_RULES：sample 规则后面必须还有一条规则作为模板" \
                    "sample K 的语义是把排序后前 K 张表交给下一条规则的策略处理" \
                    "在 sample 规则下面再加一行规则（如 full 或 window …）"
                IFS='|' read -r _ next_strat next_a1 next_a2 <<< "${next_rule}"
                local sorted i
                mapfile -t sorted < <(printf '%s\n' "${matches[@]}" | sort -t $'\t' -k2,2)
                for ((i = 0; i < ${#sorted[@]}; i++)); do
                    IFS=$'\t' read -r sch tbl bytes <<< "${sorted[${i}]}"
                    if (( i < kk )); then
                        apply_strategy "${sch}" "${tbl}" "${bytes}" "${next_strat}" "${next_a1}" "${next_a2}"
                    else
                        plan_row "${sch}" "${tbl}" none - 0 OK sample-excess
                    fi
                done ;;
        esac
    done
    local row sch tbl bytes key
    for row in "${ALL_TABLES[@]}"; do
        [[ -z "${row}" ]] && continue
        IFS=$'\t' read -r sch tbl bytes <<< "${row}"
        key="${sch}.${tbl}"
        [[ -n "${CLASSIFIED[${key}]:-}" ]] && continue
        plan_row "${sch}" "${tbl}" none - 0 OK no-rule
    done
}

# ---- 锁槽账 / 磁盘账（供 00-inventory 与 20-dump-data 复用）--------------------------------
# compute_lock_budget —— 设全局 LOCK_SLOTS / LOCK_NEEDED（data 阶段，×1.2 向上取整）/ LOCK_NEEDED_RAW
compute_lock_budget() {
    local max_locks max_conn max_prep cur_locks needed=0 row strat
    for row in "${PLAN_ROWS[@]}"; do
        strat="$(cut -f3 <<< "${row}")"
        [[ "${strat}" == full || "${strat}" == window ]] && needed=$((needed + 1))
    done
    max_locks="$(psql_ro "${SRC_DB}" -c 'show max_locks_per_transaction')"
    max_conn="$(psql_ro "${SRC_DB}" -c 'show max_connections')"
    max_prep="$(psql_ro "${SRC_DB}" -c 'show max_prepared_transactions')"
    cur_locks="$(psql_ro "${SRC_DB}" -c 'select count(*) from pg_locks')"
    LOCK_SLOTS=$(( max_locks * (max_conn + max_prep) - cur_locks ))
    LOCK_NEEDED_RAW=${needed}
    LOCK_NEEDED=$(( (needed * 12 + 9) / 10 ))
}

# disk_free_bytes <路径> —— 该路径所在文件系统的可用字节数
disk_free_bytes() {
    df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' '
}

# est_bytes_total —— PLAN_ROWS 里 full/window 两类策略的 est_bytes 之和（== 计划实际会 dump 的估算总量）
est_bytes_total() {
    local total=0 row strat bytes
    for row in "${PLAN_ROWS[@]}"; do
        strat="$(cut -f3 <<< "${row}")"
        bytes="$(cut -f5 <<< "${row}")"
        [[ "${strat}" == full || "${strat}" == window ]] && total=$((total + bytes))
    done
    echo "${total}"
}

# strategy_count <strategy> —— PLAN_ROWS 里某策略的行数
strategy_count() {
    local strat="$1" c=0 row
    for row in "${PLAN_ROWS[@]}"; do
        [[ "$(cut -f3 <<< "${row}")" == "${strat}" ]] && c=$((c + 1))
    done
    echo "${c}"
}
