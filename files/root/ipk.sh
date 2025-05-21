#!/bin/sh

# 当任何命令执行失败时立即退出脚本
set -e

# 定义预安装目录、归档文件名和下载 URL
PRE_INSTALL_DIR="/root/ipk"
ARCHIVE_NAME="ipk.tar.gz"
# 注意：此 URL 指向一个名为 ipk.tar.gz 的特定版本文件，而不是一个 git 仓库。
ARCHIVE_URL="https://github.com/FreddyZeng/ipk/releases/download/1.0/$ARCHIVE_NAME"

# 检查 PRE_INSTALL_DIR 是否存在。
# 如果不存在，则创建该目录，然后下载并解压 IPK 包。
if [ -d "$PRE_INSTALL_DIR" ]; then
    echo "目录 '$PRE_INSTALL_DIR' 已存在。"
    echo "假设 IPK 文件已准备就绪或先前已解压，跳过下载和解压步骤。"
else
    echo "目录 '$PRE_INSTALL_DIR' 不存在。"
    echo "正在创建目录 '$PRE_INSTALL_DIR'..."
    mkdir -p "$PRE_INSTALL_DIR"
    # mkdir 的成功由 set -e 保证。如果失败，脚本将在此处退出。

    echo "正在将 IPK 包 '$ARCHIVE_NAME' 下载到 '$PRE_INSTALL_DIR' 目录中..."
    # 使用 -O 参数指定输出文件的完整路径和名称。
    # 添加 --no-verbose 以减少 wget 的输出，或移除它以查看详细下载过程。
    if ! wget --no-verbose "$ARCHIVE_URL" -O "$PRE_INSTALL_DIR/$ARCHIVE_NAME"; then
        echo "错误: 下载 '$ARCHIVE_NAME' 失败。请检查网络连接或 URL ($ARCHIVE_URL)。"
        # 如果下载失败，可以选择删除已创建的 PRE_INSTALL_DIR 以进行清理
        # rm -rf "$PRE_INSTALL_DIR"
        exit 1 # set -e 会处理退出，但明确的错误消息对用户更友好
    fi
    echo "IPK 包 '$ARCHIVE_NAME' 下载完成。"

    echo "正在解压 '$PRE_INSTALL_DIR/$ARCHIVE_NAME' 到 '$PRE_INSTALL_DIR' 目录..."
    # 使用 tar 命令解压。
    # -x: extract (解压)
    # -z: filter through gzip (处理 .gz 压缩)
    # -f: use archive file (指定归档文件)
    # -C "$PRE_INSTALL_DIR": change to directory PRE_INSTALL_DIR before performing any operations (确保解压到目标目录内)
    if ! tar -xzf "$PRE_INSTALL_DIR/$ARCHIVE_NAME" -C "$PRE_INSTALL_DIR"; then
        echo "错误: 解压 '$PRE_INSTALL_DIR/$ARCHIVE_NAME' 失败。"
        echo "可能文件已损坏，不是有效的 tar.gz 文件，或者目标目录空间不足。"
        exit 1 # set -e 会处理退出
    fi
    echo "IPK 包解压完成。"

    echo "正在删除已解压的压缩包 '$PRE_INSTALL_DIR/$ARCHIVE_NAME'..."
    if ! rm "$PRE_INSTALL_DIR/$ARCHIVE_NAME"; then
        # 压缩包删除失败通常不是致命错误，脚本的主要任务（安装 IPK）仍可继续
        echo "警告: 删除压缩包 '$PRE_INSTALL_DIR/$ARCHIVE_NAME' 失败。您可以稍后手动删除。"
    else
        echo "压缩包 '$PRE_INSTALL_DIR/$ARCHIVE_NAME' 已成功删除。"
    fi
fi

echo "-----------------------------------------------------"
echo "在 '$PRE_INSTALL_DIR' 目录中递归搜索 .ipk 文件并强制安装..."
echo "-----------------------------------------------------"

# 递归查找 PRE_INSTALL_DIR 目录下的所有 .ipk 文件
# 并对每个找到的 .ipk 文件执行 opkg install 命令
# 使用 -exec sh -c '...' sh {} + 的方式可以高效处理多个文件，并能正确处理文件名中可能包含的特殊字符
# find 会将找到的文件路径列表传递给内联 sh 脚本，内联脚本通过循环处理它们。
find "$PRE_INSTALL_DIR" -type f -name "*.ipk" -exec sh -c '
    # "$@" 会展开为所有由 find 传递过来的文件路径列表
    for ipk_file_path do
        echo "==> 准备安装: $ipk_file_path"

        # 使用 opkg 强制安装 IPK 文件
        # --force-reinstall: 强制重新安装已安装的软件包
        # --force-overwrite: 强制覆盖属于其他软件包的文件
        # --force-depends: 强制安装，忽略依赖问题 (警告：这可能导致系统不稳定或软件包功能异常)
        opkg install "$ipk_file_path" --force-reinstall --force-overwrite --force-depends

        # 检查上一条命令 (opkg install) 的退出状态
        if [ $? -eq 0 ]; then
            echo "    成功安装: $ipk_file_path"
        else
            # $? 会保存 opkg install 命令的错误码
            echo "    安装失败: $ipk_file_path (错误码: $?)"
            # 由于 set -e 已设置，如果 opkg install 失败，脚本通常会在此处因 opkg 的非零退出状态而退出。
            # 如果希望即使某个 ipk 安装失败也继续尝试安装其他 ipk，
            # 你需要在此 opkg 命令前加上 'set +e;' 并在之后用 'set -e;' 恢复，
            # 或者在 opkg install 命令本身后面加上 '|| true' 来忽略其失败，
            # 或者直接移除脚本开头的 'set -e' (不推荐，除非你明确知道其影响)。
        fi
        echo "-----------------------------------------------------"
    done
' sh {} +  # 'sh' 是传递给 sh -c 的 $0 参数，'{} +' 会将找到的文件作为参数列表传递给内联脚本

echo "所有找到的 .ipk 文件处理完毕。"

exit 0
