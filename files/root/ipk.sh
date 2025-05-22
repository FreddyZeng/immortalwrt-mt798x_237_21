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

# 过滤掉 macOS 资源文件和其他非 ipk
find "$PRE_INSTALL_DIR" -type f -name "*.ipk" ! -name "._*" | while read -r ipk; do
    echo "==> 准备安装: $ipk"

    # 解压验证
    mkdir -p /tmp/ipktmp
    if ! tar -tf "$ipk" > /dev/null 2>&1; then
        echo "    🚫 无法解压，可能是损坏的 IPK 文件: $ipk"
        continue
    fi

    # 读取 control 文件中的 Package 字段
    PKG_NAME=$(tar -xOf "$ipk" ./control.tar.gz 2>/dev/null | tar -xzOf - ./control 2>/dev/null | grep '^Package:' | cut -d' ' -f2)
    if [[ -z "$PKG_NAME" ]]; then
        echo "    🚫 读取不到 Package 名称，跳过。"
        continue
    fi

    # 强制安装
    opkg install --force-depends --force-overwrite --force-reinstall "$ipk"
    if [[ $? -ne 0 ]]; then
        echo "    ❌ 安装失败: $ipk"
    else
        echo "    ✅ 成功安装: $ipk"
    fi
    echo "-----------------------------------------------------"
done

echo "所有找到的 .ipk 文件处理完毕。"

exit 0
