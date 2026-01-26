#!/bin/bash
# Distributed swe-bench evaluation with safe conda activation

# 获取脚本所在目录
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="${SCRIPT_DIR}/.swebench.env"
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
else
    echo "Error: $ENV_FILE not found"
    exit 1
fi

# ---------------- 配置 ----------------
# MODEL_NAME, BASE_PRED_DIR, NUM_ITER, CONDA_ENV, PROJECT_DIR 均可由 .swebench.env 提供
BASE_PRED_DIR=${BASE_PRED_DIR:-"${PROJECT_DIR}/results/inference"}
: "${MODEL_NAME:?MODEL_NAME environment variable not set}"
NUM_ITER=${NUM_ITER:-10}


# 每台机器负责的迭代区间，假设有3台机器10次迭代计算：
NODES=(
    "$MASTER_IP:1:4"
    "${SLAVE_IPS[0]}:5:7"
    "${SLAVE_IPS[1]}:8:10"
)
# ---------------------------------------

run_iterations() {
    local ip=$1
    local start=$2
    local end=$3

    echo ">>> Submitting tasks to $ip for iterations $start to $end"

    # 远程执行脚本逻辑
    # 我们将环境变量文件的加载直接写在远程命令的最开始
    CMD_REMOTE="
        # 1. 直接加载环境配置文件（确保远程节点能拿到最新配置）
        ENV_FILE=\"${PROJECT_DIR}/.swebench.env\"
        if [[ -f \"\$ENV_FILE\" ]]; then
            source \"\$ENV_FILE\"
        else
            echo \"Error: \$ENV_FILE not found on \$(hostname)\"
            exit 1
        fi

        # 2. 进入项目目录
        cd \"\$PROJECT_DIR\" || exit 1

        # 3. 初始化并激活 Conda
        source \"\${CONDA_BASE}/etc/profile.d/conda.sh\" 2>/dev/null || source ~/.bashrc
        source \"\${CONDA_BASE}/bin/activate\" \"\$CONDA_ENV\"
        
        # 4. 执行循环
        for i in \$(seq $start $end); do
            PRED_PATH=\"\${BASE_PRED_DIR}/\${MODEL_NAME}/output_\${i}_processed.jsonl\"
            
            if [[ -f \"\$PRED_PATH\" ]]; then
                echo \">>> [Host: $ip] Starting iteration \$i\"
                python -W ignore::RuntimeWarning -m swebench.harness.run_evaluation \\
                    --dataset_name \"\${DATASET_PATH}\" \\
                    --predictions_path \"\$PRED_PATH\" \\
                    --max_workers 32 \\
                    --run_id \"\${MODEL_NAME}-goldloc-\${i}\"
            else
                echo \"Warning: \$PRED_PATH not found on $ip, skipping...\"
            fi
        done
    "

    # 判断是否为本机
    if [[ "$ip" == $MASTER_IP || "$ip" == "$(hostname -I | awk '{print $1}')" ]]; then
        bash -c "$CMD_REMOTE" &
    else
        # 通过 stdin 传递脚本，完全避免引号嵌套引发的语法错误
        ssh -o StrictHostKeyChecking=no "$ip" "bash -s" <<< "$CMD_REMOTE" &
    fi
}

# ---------------- 主循环 ----------------
for node in "${NODES[@]}"; do
    IFS=":" read -r ip start end <<< "$node"
    run_iterations "$ip" "$start" "$end"
done

wait
echo ">>> All evaluations submitted and completed."
