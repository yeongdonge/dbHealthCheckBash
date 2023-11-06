#!/bin/bash
#-------------------------------------------------------------

customer="락플레이스"
engineer="김동영"
manager="임종민"
read -ep "Enter the DB username : " username
read -esp "Enter the Password : " password 
echo
read -ep "Enter the my.cnf path (Absolute Path) : " my_cnf


#-------------------------------------------------------------
yyyymmdd_today=`date "+%Y%m%d"` 
yyyy_mm_dd_today=`date "+%Y-%m-%d"`
html_path=$yyyymmdd_today.html
result_file=$yyyymmdd_today.log
result_path=$(pwd)/${yyyymmdd_today}/
mkdir ${result_path}
#-------------------------------------------------------------
####################################################################
#
# Function Initialize
#
####################################################################
#

convert_memory() {
  value=$1
  unit=$2

    case $unit in
    "KB" | "kb")
      converted=$(awk "BEGIN {print $value}")
      echo "$converted KB"
      ;;
    "MB" | "mb")
      converted=$(awk "BEGIN {print $value / 1024 }")
      echo "$converted MB"
      ;;
    "GB" | "gb")
      converted=$(awk "BEGIN {print $value / 1024 / 1024}")
      echo "$converted GB"
      ;;
    *)
      echo "Invalid unit. Supported units: KB, MB, GB"
      ;;
  esac
}


convert_size() {
  local size=$1
  local bias=0

  while [ $size -ge 1024 ]; do
      size=$((size / 1024))
      bias=$((bias + 1))
  done

  case $bias in
    0) unit="Btye";;
    1) unit="KB";;
    2) unit="MB";;
    3) unit="GB";;
    4) unit="TB";;
  esac

  echo "$size$unit"
}


except() {
    echo "   "
    echo "$1"
    echo "Terminated"
    echo "   "
    exit
}

get_cnf_element() {
    element=$(grep "^$1" ${my_cnf} | awk -F "=" '{print $2}' | tr -d ' ' | head -n 1)
    echo ${element}
}

get_socket() {
    if [ -z "${1}" ];
    then
        socket=/tmp/mysql.sock
    fi
}


create_extra_cnf() {
echo "
[mysql]
user="${username}"
password="${password}"
socket="${socket}"
" > $1
}


cnf_inavlid_check() {
    if [ ! -f "$1" ];
    then
        except "No such MySQL Configuration file"
    fi
}

basedir_invalid_check() {
    if [ -z "$1" ];
    then
        except "Must include 'basedir' values in ${my_cnf} File."
    fi
}

get_sql_result() {
    client=${basedir}/bin/mysql
    sql_result=$( ${client} --defaults-extra-file=my_ext.cnf -sN -e "$1" )
    echo ${sql_result}
}

get_os_ver() {
    release_file=$(ls /etc/*release* 2>/dev/null | head -n 1)

    if [[ -f "$release_file" ]]; then
        cat ${release_file}
    fi
}

get_total_mem() {
    mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    echo ${mem_total}
}

get_cpu_model() {
    cpu_model=$(lscpu | grep 'Model name:' | awk -F ':' '{print $2}' | sed -e 's/^[ \t]*//')
    echo ${cpu_model}
}

get_disk_usage() {
    disk_usage=$(df $1 | awk 'NR==2 {print $5}')
    echo ${disk_usage}
}

get_innodb_data_file_size() {
    ib_files=$(echo $2 | awk -v dir="${1}/" -F ';|:' '{for(i=1; i<NF; i+=2) if($i!="autoextend") printf dir $i" "}')
    ib_file_size=$(du -sch ${ib_files} | grep -E "total|합계" | awk '{print $1}')
    echo $ib_file_size
}

get_binary_log_file_size() {
    binary_log_basename=${1}
    binary_log_file_size=$(du -sch ${binary_log_basename}.* | grep -E "total|합계" | awk '{print $1}')
    echo $binary_log_file_size
}

get_relay_log_file_size() { ## 첫 번째 파라미터에 Master 여부를 확인
    server_type=${1}
    relay_log_basename=$( ${client} --defaults-extra-file=my_ext.cnf -sN -e "select @@relay_log_basename")
    case "${server_type}" in
        "Master")
            relay_log_file_size="-"
        ;;
        "Standalone")
            relay_log_file_size="-"
        ;;
        *) ## Slave일 경우
            if [ "NULL" == "${relay_log_basename}" ]  ## basename 공란 일 경우 Defualt (datadir)
            then
                datadir=$( ${client} --defaults-extra-file=my_ext.cnf -sN -e "select @@datadir")
                hostname=$( ${client} --defaults-extra-file=my_ext.cnf -sN -e "select @@hostname")
                relay_log_file_name="${datadir}/${hostname}-relay-bin.*"
                relay_log_file_size=$(du -sch ${relay_log_file_name} | grep -E "total|합계" | awk '{print $1}')
            else
                relay_log_file_name=$( ${client} --defaults-extra-file=my_ext.cnf -sN -e "select @@relay_log_basename")
                relay_log_file_size=$(du -sch ${relay_log_file_name}.* | grep -E "total|합계" | awk '{print $1}')
            fi
        ;;
    esac

    echo ${relay_log_file_size}
}

get_memory_usage() {
    # memory_usage=$(top -b n 1 | grep -w mysqld | awk '{print $10}')
    memory_usage=$({ ps -C mysqld -o %mem; ps -C mariadbd -o %mem; } | awk 'NR > 1 && $1 > 0 {print}')
    echo "${memory_usage}%"
}

get_tps() {
    tps=$(echo "scale=2; ($1 + $2) / $3" | bc)
    printf "%.2f\n" $tps
}

is_enabled_key_buffer() {
    if [[ $1 -le 0 ]];
    then
        echo '-'
    fi
}

convert_seconds_to_date () {
    days=$(( $1 / ((60 * 60) * 24)))
    hours=$(( $1 / (60 * 60) % 24 )) 

    echo "${days} days ${hours} hours"
}

export_innodb_status() {
    client=${basedir}/bin/mysql
    `${client} --defaults-extra-file=my_ext.cnf -sN -e "show engine innodb status\G"  > ${result_path}/innodb_status.log`
}

server_type_check() {

    client=${basedir}/bin/mysql
    slave_status_check=$( ${client} --defaults-extra-file=my_ext.cnf -sN -e "show slave status\G")
    binlog_process_check=$( ${client} --defaults-extra-file=my_ext.cnf -sN -e "select state from information_schema.processlist where state like '%has sent all binlog%'" | awk 'NR==1' )
    read_only_value=$( ${client} --defaults-extra-file=my_ext.cnf -sN -e "select @@read_only")

    if [ -n "${binlog_process_check}" ] && [ -n "${slave_status_check}" ]
    then
        if [ 0 -eq "${read_only_value}" ]
            then
                server_type="Multi Master"
            else
                server_type="Chain Slave"
        fi
    else
        if [ -n "${binlog_process_check}" ]
            then
                server_type="Master"
        elif [ -n "${slave_status_check}" ]
            then   
                server_type="Slave"
            else
                server_type="Standalone"
            fi
    fi

    case "${server_type}" in
    "Master")
    ;;
    "Standalone")
    ;;
    *)
         IO_running=$( ${client} --defaults-extra-file=my_ext.cnf -s -e "show slave status\G" | grep 'IO_Running:' | awk '{print $2}')
         SQL_running=$( ${client} --defaults-extra-file=my_ext.cnf -s -e "show slave status\G" | grep 'SQL_Running:' | awk '{print $2}')
         if [ "Yes" == "${IO_running}" ] && [ "Yes" == "${SQL_running}" ]
            then
                server_type="Slave status OK"
            elif [ "Yes" != "${IO_running}" ] && [ "Yes" == "${SQL_running}" ]
                then
                    server_type="IO Running Err!!"
            elif [ "Yes" != "${SQL_running}" ] && [ "Yes" == "${IO_running}" ]
                then
                    server_type="SQL Running Err!!"
        else
            server_type="IO/SQL Running Err!!"
        fi
    esac

    echo ${server_type}
}

check_fk_error() {
    check_fk_message=""
         `grep -A99999 "LATEST FOREIGN KEY ERROR" ${result_path}/innodb_status.log | grep -B99999 -m2 -e "------------------------" > ${result_path}/fk_error.log`
    if [ -s "${result_path}/fK_error.log" ]; then
        check_fk_message="FK Error exists"
    else
        check_fk_message="OK"
    fi

    echo ${check_fk_message}
}

check_dead_lock() {
    check_dead_lock_message=""
    `grep -A99999 "LATEST DETECTED DEADLOCK" ${result_path}/innodb_status.log | grep -B99999 "WE ROLL BACK TRANSACTION" > ${result_path}/deadlock.log`
    if [ -s "${result_path}/deadlock.log" ]; then
        check_dead_lock_message="DEADLOCK exists"
    else
        check_dead_lock_message="OK"
    fi
    echo ${check_dead_lock_message}
}

check_innodb_status() { ## 첫 번째 파라미터는 dead lock, 두 번째 파라미터는 fk error
    innodb_status_message=""
    if [ "OK" == "${1}" ] && [ "OK" == "${2}" ] 
        then
            innodb_status_message="OK"
    elif [ "OK" != "${1}" ] && [ "OK" == "${2}" ]
        then
            innodb_status_message="DEADLOCK"
    elif [ "OK" != "${2}" ] && [ "OK" == "${1}" ]
        then
            innodb_status_message="FK ERROR"
    else
        innodb_status_message="DEADLOCK/FK ERROR"
    fi

    echo "${innodb_status_message}"   
}

check_recommended_value() { ## 첫 번쨰 파라미터는 현재 값, 두 번째 파라미터는 권고치, 세 번째 파라미터는 권고치보다 큰지 낮은지 확인 (up, down)
    result=""
    
    current_value=$(echo "${1}" | sed -E 's/[^0-9.]+//g')
    # current_value=$(echo "${1}" | sed -E 's/^[^0-9]*([0-9]+(\.[0-9]+)?).*$/\1/')

    recommended_value=${2}

    if [ -z "${current_value}" ]
        then
            result="양호"
    else
    case "${3}" in
        "down" | "DOWN")
            if (( $(echo "$current_value <= $recommended_value" | bc -l) ))
            then   
                result="양호"
            else
                result="주의"
            fi
        ;;
        "up" | "UP")
            if (( $(echo "$current_value >= $recommended_value" | bc -l) )) 
            then
                result="양호"
            else
                result="주의"
            fi
        ;;
        *)
            result="Invalid Parameter"
    esac
    fi

    echo ${result}
}

check_recommended_value_2() { ## 데드락 등 숫자가 아닌 문자열 형식의 결과값의 경우, 첫 번째 파라미터는 현재 값
    result_message="${1}"
    return_message=""

    if echo "${result_message}" | grep -qE "OK|Master|Standalone|" ; then
        return_message="양호"
    else
        return_message="주의"
    fi

    echo "${return_message}"
}

write_data_size_to_arr() {
    file_path="data.log"  # 파일 경로를 지정합니다.
    new_month=$(date +%m)
    if [[ ${1} =~ ^([0-9.]+)([A-Za-z]+)$ ]]; then
        number="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"

    if [ -e "$file_path" ]; then
        # 파일이 존재하는 경우 기존 데이터를 읽어옵니다.
        existing_data=$(cat "$file_path")

        existing_months=$(awk 'NR == 1' <<< "$existing_data")
        existing_data=$(awk 'NR == 2' <<< "$existing_data")

        # 기존 데이터가 존재하는 경우에만 데이터를 업데이트합니다.
        if [ -n "$existing_months" ] && [ -n "$existing_data" ]; then
            updated_months="$existing_months, ${new_month}"
            updated_data="$existing_data, $number"
        else
            updated_months="${new_month}"
            updated_data="$number"
        fi

        updated_data_arr="${updated_months}\n${updated_data}"

        echo -e "$updated_data_arr" > "$file_path"

    else
        # 파일이 존재하지 않으면 새로운 파일을 생성합니다.
        cat <<EOF > "${file_path}"
${new_month}
${number}
EOF
    fi
fi

echo "${unit}"
}

optimize_chart_graph() {
    file_path="data.log"
    months=("01" "02" "03" "04" "05" "06" "07" "08" "09" "10" "11" "12")
    new_month_array=()
    new_data_array=()

    readarray -t lines < "$file_path"
    existing_months=(${lines[0]//,/ })
    existing_data=(${lines[1]//,/ })


    if [ ${#existing_months[@]} -gt 5 ]; then
        for ((i = 0; i < 5; i++)); do
            index=$(( (i + ${#existing_months[@]} - 5) % ${#existing_months[@]} ))
            new_month_array+=("\"${existing_months[$index]}\"")  # 월 값을 문자열로 처리
            new_data_array+=(${existing_data[$index]})
        done
    else
        for ((i = 0; i < ${#existing_months[@]}; i++)); do
            new_month_array+=("\"${existing_months[$i]}\"")  # 월 값을 문자열로 처리
        done
        for ((i = ${#existing_months[@]}; i < 5; i++)); do
            last_month=${existing_months[-1]}
            next_month_index=$(( ((10#${last_month} + i - ${#existing_months[@]}) % 12) ))
            next_month="${months[$next_month_index]}"
            new_month_array+=("\"$next_month\"")  # 월 값을 문자열로 처리
            new_data_array=("${existing_data[@]}")
        done
    fi
    

    new_month_string=$(IFS=, ; echo "${new_month_array[*]}")
    new_data_string=$(IFS=, ; echo "${new_data_array[*]}")
    results=("$new_month_string" "$new_data_string")
    echo "${results[@]}"
}





#################################################################
cnf_inavlid_check ${my_cnf}
basedir=$(get_cnf_element 'basedir')
basedir_invalid_check ${basedir}
socket=$(get_cnf_element 'socket')
$(get_socket $socket)
create_extra_cnf my_ext.cnf
export_innodb_status


####################################################################
#
# SQL RESULT
#
####################################################################
#

hostname=$(get_sql_result 'select @@hostname')
port=$(get_sql_result 'select @@port')
datadir=$(get_sql_result 'select @@datadir')
binary_log=$(get_sql_result 'select @@log_bin_basename')
error_log=$(get_sql_result 'select @@log_error')
version=$(get_sql_result 'select version()')
slow_query_log=$(get_sql_result 'select @@slow_query_log_file')
data_index_size=$(convert_size $(get_sql_result 'select sum(index_length+data_length) from information_schema.tables'))
schema_of_global_status=$(get_sql_result "select case when cnt = 2 and perf = 1 then 'performance_schema' when cnt = 2 and perf = 0 then 'information_schema' else (select table_schema from information_schema.tables where table_name like '%global_status%' and table_schema <> 'sys') end from (select count(*) cnt , @@performance_schema as perf from  information_schema.tables where table_name like '%global_status%' and table_schema <> 'sys') as main")
innodb_data_home_dir=$(get_sql_result "select @@innodb_data_home_dir")
innodb_data_file_path=$(get_sql_result "select @@innodb_data_file_path")
innodb_buffer_pool_hit_rate=$(get_sql_result "select round(100-(b.variable_value/(a.variable_value + b.variable_value)) * 100,2)  from ${schema_of_global_status}.global_status a, ${schema_of_global_status}.global_status b where a.variable_name='innodb_buffer_pool_read_requests' and b.variable_name = 'innodb_buffer_pool_reads'")% 
key_buffer_hit_rate=$(is_enabled_key_buffer $(get_sql_result "select round(100-(b.variable_value/(a.variable_value + b.variable_value)) * 100,2)  from ${schema_of_global_status}.global_status a, ${schema_of_global_status}.global_status b where a.variable_name='key_read_requests' and b.variable_name = 'key_reads'"))% 
thread_cache_miss_rate=$(get_sql_result "select round(b.variable_value / a.variable_value * 100,2)  from ${schema_of_global_status}.global_status a, ${schema_of_global_status}.global_status b where a.variable_name='connections' and b.variable_name = 'threads_created'")%
index_usage=$(get_sql_result "select round((100-(((a.variable_value + b.variable_value)/(a.variable_value + b.variable_value + c.variable_value + d.variable_value + e.variable_value + f.variable_value)) * 100)),2) from ${schema_of_global_status}.global_status a, ${schema_of_global_status}.global_status b, ${schema_of_global_status}.global_status c, ${schema_of_global_status}.global_status d, ${schema_of_global_status}.global_status e, ${schema_of_global_status}.global_status f where a.variable_name = 'handler_read_rnd_next'
and b.variable_name = 'handler_read_rnd' and c.variable_name = 'handler_read_first' and d.variable_name = 'handler_read_next' and e.variable_name = 'handler_read_key' and f.variable_name = 'handler_read_prev'")%
max_used_connect=$(get_sql_result "select round(variable_value / @@max_connections, 2) from ${schema_of_global_status}.global_status where variable_name='max_used_connections'")%
aborted_connects=$(get_sql_result "select round((a.variable_value / b.variable_value), 2) * 100 from ${schema_of_global_status}.global_status a, ${schema_of_global_status}.global_status b where a.variable_name='aborted_connects' and b.variable_name='connections'")%
tmp_disk_rate=$(get_sql_result "select round(a.variable_value / (a.variable_value + b.variable_value) * 100,2) from ${schema_of_global_status}.global_status a, ${schema_of_global_status}.global_status b where a.variable_name='created_tmp_disk_tables' and b.variable_name='created_tmp_tables'")%
uptime=$(get_sql_result "select variable_value from ${schema_of_global_status}.global_status where variable_name='uptime'")
converted_uptime=$(convert_seconds_to_date ${uptime})
rollback_segment=$(get_sql_result "select count from information_schema.innodb_metrics where name='trx_rseg_history_len'")
qps=$(get_sql_result "select round(a.variable_value / b.variable_value, 2) from ${schema_of_global_status}.global_status a, ${schema_of_global_status}.global_status b where a.variable_name='questions' and b.variable_name='uptime'")
com_commit=$(get_sql_result "show global status like 'com_commit'")
com_rollback=$(get_sql_result "show global status like 'com_rollback'")
com_commit_value=$(echo ${com_commit} | awk '{print $2}')
com_rollback_value=$(echo ${com_rollback} | awk '{print $2}')
tps=$(get_tps ${com_commit_value} ${com_rollback_value} ${uptime})
dead_lock_status=$(check_dead_lock)
fk_error_status=$(check_fk_error)
innodb_status_message=$(check_innodb_status ${dead_lock_status} ${fk_error_status})
innodb_data_file_size=$(get_innodb_data_file_size ${innodb_data_home_dir} ${innodb_data_file_path})
server_type=$(server_type_check)
binary_log_file_size=$(get_binary_log_file_size ${binary_log})
relay_log_file_size=$(get_relay_log_file_size ${server_type})
select_full_join=$(get_sql_result "select variable_value from ${schema_of_global_status}.global_status where variable_name='select_full_join'")
select_scan=$(get_sql_result "select variable_value from ${schema_of_global_status}.global_status where variable_name='select_scan'")
sort_merge_passes=$(get_sql_result "select variable_value from ${schema_of_global_status}.global_status where variable_name='sort_merge_passes'")
graph_unit=$(write_data_size_to_arr ${data_index_size})
optimize_chart=($(optimize_chart_graph))
graph_months=${optimize_chart[0]}
graph_data=${optimize_chart[1]}


####################################################################
#
# OS RESULT
#
####################################################################
#
os_ver=$(get_os_ver)
disk_usage=$(get_disk_usage ${datadir})
mem_total=$(convert_memory $(get_total_mem) "GB")
cpu_model=$(get_cpu_model)
memory_usage=$(get_memory_usage)

####################################################################
#
# DEBUGGING
#
####################################################################
#

####################################################################
#
# MAKE HTML
#
####################################################################
#


cat <<EOF > "${result_path}/${html_path}"
<!DOCTYPE html>
<html lang='en'>

<head>
    <meta charset='UTF=8'>
</head>

<body style='width: 100%; margin: auto;'>
    <p style='text-align: center; font-size: 2em; font-weight: 1000; margin-bottom: 0.5em;'>유지보수 점검 확인서</p>
    <div style='overflow: auto;'>
        <span style='float: left;'>SITE : ${customer}</span>
        <span style='float: right;''>엔지니어 : ${engineer} (인)</span>
    </div>
    <div style=' overflow: auto;'>
            <span style='float: left'>DATE : ${yyyy_mm_dd_today}</span>
            <span style='float: right;'>담당자 : ${manager} (인)</span>
    </div>
    <div>
        <div class='container' style='margin-top: 10px;'>
            <div class='title' style='margin-top: 10px; flex: 1;'>
                <div style='border-bottom: solid 0.1em black;'>Service</div>
                <div style='border-bottom: solid 0.1em black;'>Hostname</div>
                <div style='border-bottom: solid 0.1em black;'>OS ver.</div>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>DBMS ver.</div>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>CPU</div>
                <div style='padding-left: 5px;'>Memory</div>
            </div>
            <div style='margin-top: 10px; flex: 2; border-top: solid 0.1em; border-bottom: solid 0.1em;'>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>${customer}</div>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>${hostname}</div>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>${os_ver}</div>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>${version}</div>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>${cpu_model}</div>
                <div style='padding-left: 5px;'>${mem_total}</div>
            </div>
            <div class='title' style='margin-top: 10px; flex: 1'>
                <div style='border-bottom: solid 0.1em black;'>Port</div>
                <div style='border-bottom: solid 0.1em black;'>Basedir</div>
                <div style='border-bottom: solid 0.1em black;'>Datadir</div>
                <div style='border-bottom: solid 0.1em black;'>Binary Log</div>
                <div style='border-bottom: solid 0.1em black;'>Error Log</div>
                <div>Slow query Log</div>
            </div>
            <div
                style='margin-top: 10px; flex: 2; border-top: solid 0.1em; border-bottom: solid 0.1em; border-right: solid 0.1em;'>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>${port}</div>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>${basedir}</div>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>${datadir}</div>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>${binary_log}</div>
                <div style='border-bottom: solid 0.1em black; padding-left: 5px;'>${error_log}</div>
                <div style='padding-left: 5px;'>${slow_query_log}</div>
            </div>
        </div>

        <div style='border: solid 0.1em black;'>
            <div class='container' style='margin-top: 10px;'>
                <span class='title'>항목</span>
                <span class='title'>세부 항목</span>
                <span class='title'>기준값</span>
                <span class='title'>점검결과값</span>
                <span class='title'>점검결과</span>
            </div>
            <div class='container' style='margin-top: 0px;'>
                <span class='content'>OS</span>
                <span class='content'>Disk Usage</span>
                <span class='content'>80% 이하</span>
                <span class='content'>${disk_usage}</span>
                <span class='content' id='result'>$(check_recommended_value ${disk_usage} 80 down)</span>
            </div>
            <div class='container' style='margin-top: 0px;'>
                <span class='content'>Data & Index Size</span>
                <span class='content'>데이터와 인덱스 크기</span>
                <span class='content'>N/A</span>
                <span class='content'>${data_index_size}</span>
                <span class='content' id='result'>양호</span>
            </div>
            <div class='container' id='graph' style='margin-top: 0px;'>
                <canvas id='myChart' style='width: 350; height:220px'></canvas>
                <script src='Chart.min.js'></script>
                <script src='https://cdn.jsdelivr.net/npm/chart.js'></script>
                <script>
                    const ctx = document.getElementById('myChart');

                    var myChart = new Chart(ctx, {
                        type: 'bar',
                        data: {
                            labels: [ ${graph_months} ] ,
                        datasets: [{
                            label: '# Data & Index size (${graph_unit})',
                            data: [ ${graph_data} ],
                            borderWidth: 1
                        }]
                        },
                    options: {
                        responsive: false,
                            maintainAspectRatio: true,
                                scales: {
                            y: {
                                beginAtZero: true
                            }
                        }
                    }
                    });
                </script>
            </div>
            <div class='container' style='margin-top: 0px; border-top: solid 0.1em black;'>
                <span class='content'>Ibdata Size</span>
                <span class='content'>System Tablespace 크기</span>
                <span class='content'>N/A</span>
                <span class='content'>${innodb_data_file_size}</span>
                <span class='content' id='result'>양호</span>
            </div>
            <div class='container' style='margin-top: 0px;'>
                <span class='content'>Memory Usage</span>
                <span class='content'>메모리 사용률</span>
                <span class='content'>80% 이하</span>
                <span class='content'>${memory_usage}</span>
                <span class='content' id='result'>$(check_recommended_value ${memory_usage} 80 down)</span>
            </div>

            <div class='container'>
                <div class='content' ;>
                    <div>　</div>
                    <div>Hit rate</div>
                    <div>　</div>
                </div>
                <div class='content'>
                    <div>InnoDB Buffer Pool hit rate</div>
                    <div>Key Buffer hit rate</div>
                    <div>Thread Cache miss rate</div>
                </div>
                <div class='content'>
                    <div>
                        <div>90% 이상</div>
                        <div>90% 이상</div>
                        <div>10% 이하</div>
                    </div>
                </div>
                <div class='content'>
                    <div>
                        <div>${innodb_buffer_pool_hit_rate}</div>
                        <div>${key_buffer_hit_rate}</div>
                        <div>${thread_cache_miss_rate}</div>
                    </div>
                </div>
                <div class='content'>
                    <div id='result'>$(check_recommended_value ${innodb_buffer_pool_hit_rate} 90 up)</div>
                    <div id='result'>$(check_recommended_value ${key_buffer_hit_rate} 90 up)</div>
                    <div id='result'>$(check_recommended_value ${thread_cache_miss_rate} 10 down)</div>
                </div>
            </div>

            <div class='container' style='margin-top: 0px;'>
                <span class='content'>Max Connetion</span>
                <span class='content'>최대 접속된 세션 수</span>
                <span class='content'>80% 이하</span>
                <span class='content'>${max_used_connect}</span>
                <span class='content' id='result'>$(check_recommended_value ${max_used_connect} 80 down)</span>
            </div>
            <div class='container' style='margin-top: 0px;'>
                <span class='content'>Connection Miss Rate</span>
                <span class='content'>Connection Miss Rate</span>
                <span class='content'>1% 이하</span>
                <span class='content'>${aborted_connects}</span>
                <span class='content' id='result'>$(check_recommended_value ${aborted_connects} 1 down)</span>
            </div>
            <div class='container' style='margin-top: 0px;'>
                <span class='content'>Created Tmp</span>
                <span class='content'>Created tmp disk tables</span>
                <span class='content'>10% 이하</span>
                <span class='content'>${tmp_disk_rate}</span>
                <span class='content' id='result'>$(check_recommended_value ${tmp_disk_rate} 10 down)</span>
            </div>
            <div class='container'>
                <div class='content'>
                    <div>　</div>
                    <div>　</div>
                    <div>Status</div>
                    <div>　</div>
                    <div>　</div>
                    <div>　</div>
                </div>
                <div class='content'>
                    <div>Uptime</div>
                    <div>History list length</div>
                    <div>QPS</div>
                    <div>TPS</div>
                    <div>InnoDB engine status</div>
                    <div>Replication slave status</div>
                </div>
                <div class='content'>
                    <div>
                        <div>N/A</div>
                        <div>N/A</div>
                        <div>N/A</div>
                        <div>N/A</div>
                        <div>N/A</div>
                        <div>N/A</div>
                    </div>
                </div>
                <div class='content'>
                    <div>
                        <div>${converted_uptime}</div>
                        <div>${rollback_segment}</div>
                        <div>${qps}</div>
                        <div>${tps}</div>
                        <div>${innodb_status_message}</div>
                        <div>${server_type}</div>
                    </div>
                </div>
                <div class='content'>
                    <div id='result'>양호</div>
                    <div id='result'>양호</div>
                    <div id='result'>양호</div>
                    <div id='result'>양호</div>
                    <div id='result'>$(check_recommended_value_2 ${innodb_status_message})</div>
                    <div id='result'>$(check_recommended_value_2 ${server_type})</div>
                </div>
            </div>
            <div class='container'>
                <div class='content'>
                    <div>DBMS Log</div>
                    <div>　</div>
                </div>
                <div class='content'>
                    <div>Binary Log</div>
                    <div>Relay Log</div>
                </div>
                <div class='content'>
                    <div>
                        <div>N/A</div>
                        <div>N/A</div>
                    </div>
                </div>
                <div class='content'>
                    <div>
                        <div>${binary_log_file_size}</div>
                        <div>${relay_log_file_size}</div>
                    </div>
                </div>
                <div class='content'>
                    <div id='result'>양호</div>
                    <div id='result'>양호</div>
                </div>
            </div>
            <div class='container'>
                <div class='content'>
                    <div>　</div>
                    <div>Full Join</div>
                    <div>　</div>
                </div>
                <div class='content'>
                    <div>select_full_join</div>
                    <div>select_scan</div>
                    <div>sort_merge_passes</div>
                </div>
                <div class='content'>
                    <div>
                        <div>N/A</div>
                        <div>N/A</div>
                        <div>N/A</div>
                    </div>
                </div>
                <div class='content'>
                    <div>
                        <div>${select_full_join}</div>
                        <div>${select_scan}</div>
                        <div>${sort_merge_passes}</div>
                    </div>
                </div>
                <div class='content'>
                    <div id='result'>양호</div>
                    <div id='result'>양호</div>
                    <div id='result'>양호</div>
                </div>
            </div>
            <div style='background-color: #DAEEF3; text-align: center; border: solid 0.1em black;'>특이사항</div>
            <div style='height: 80px; border: solid 0.1em black'>특이사항 없습니다.</div>
            <div style='background-color: #DAEEF3; text-align: center; border: solid 0.1em black;'>점검결과</div>
            <div style='height: 60px; border: solid 0.1em black'>점검결과 양호합니다.</div>
        </div>
        <footer>
            <p>&copy; 2023. (Rockplace) All rights reserved.</p>
        </footer>
</body>

</html>

<style>
    body {
        font-size: 12px;
    }

    .container {
        display: flex;
        justify-content: space-between;
        align-items: center;
    }

    .title {
        flex: 1;
        font-weight: 700;
        text-align: center;
        background-color: #DAEEF3;
        border: solid 0.1em black;
    }

    .content {
        flex: 1;
        font-weight: 350;
        text-align: center;
        border: solid 0.1em black;
    }

    .content_div {
        flex: 1;
        font-weight: 350;
        text-align: center;
    }

    footer {
        text-align: right;
    }


    .warning {
        color: red;
    }

    .good {
        color: green;
    }

    #graph {
        margin-left: 150px;
    }

    @media print {
        body {
            -webkit-print-color-adjust: exact;
            width: 210mm;
            height: 297mm;
            margin: 0;
            padding: 0;
        }
    }
</style>

<script>
    window.onload = function () {
        const boxes = document.querySelectorAll('#result');

        boxes.forEach(box => {
            const content = box.textContent.trim();

            if (content === '주의') {
                box.classList.add('warning');
            } else if (content === '양호') {
                box.classList.add('good');
            }
        });
    };
</script>
EOF

cat <<EOF > "${result_path}/${result_file}"
    ====================
    O/S Information
    ====================

    ▪ Host : ${hostname}

    ▪ OS : ${os_ver}

    ▪ Memory Usage : ${memory_usage}

    ▪ Disk Usage : ${disk_usage}

    ▪ Momory : ${mem_total}

    ▪ CPU : ${cpu_model}

    ▪ DBMS INFO
        DBMS : ${version}
        Uptime : ${uptime}
        Port : ${port}

        Basedir : ${basedir}
        Datadir : ${datadir}
        Binary Log : ${binary_log}
        Binary Log size : ${binary_log_file_size}
        Relay Log size : ${relay_log_file_size}
        Error Log : ${error_log}
        Slow Query Log : ${slow_query_log}

    ====================
    DBMS Information
    ====================

    ▪ Data & Index Size : ${data_index_size}

    ▪ ibdata Size : ${innodb_data_file_size}

    ▪ Hit rate
        Innodb Buffer Pool hit rate : ${innodb_buffer_pool_hit_rate}
        Key Buffer hit rate : ${key_buffer_hit_rate}
        Thread Cache miss rate : ${thread_cache_miss_rate}
        Index Usage : ${index_usage}
    
    ▪ Max Connection : ${max_used_connect} 

    ▪ Connection Miss rate : ${aborted_connects}

    ▪ Created tmp disk tables rate : ${tmp_disk_rate}

    ▪ Status
        History list length : ${rollback_segment}
        QPS : ${qps}
        TPS : ${tps}
        InnoDB engine status : ${innodb_status_message}
        Replication status : ${server_type}

    ▪ Full Join
        select full join : ${select_full_join}
        select_sacn : ${select_scan}
        sort_merge_passes : ${sort_merge_passes}
EOF



cat /dev/null > my_ext.cnf
clear
cat ${result_path}/${result_file}
