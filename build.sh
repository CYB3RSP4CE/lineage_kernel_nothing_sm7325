#!/bin/bash
#
# kimocoder kernel builder and packer
# 2024 - kimocoder
#

# Setup getopt.
long_opts="regen,clean,homedir:,tcdir:"
getopt_cmd=$(getopt -o rch:t: --long "$long_opts" -n "$(basename $0)" -- "$@") || \
            { echo -e "\nError: Getopt failed. Extra args\n"; exit 1; }

eval set -- "$getopt_cmd"

while true; do
    case "$1" in
        -r|--regen|r|regen) FLAG_REGEN_DEFCONFIG=y ;;
        -c|--clean|c|clean) FLAG_CLEAN_BUILD=y ;;
        -h|--homedir|h|homedir) HOME_DIR="$2"; shift ;;
        -t|--tcdir|t|tcdir) TC_DIR="$2"; shift ;;
        --) shift; break ;;
    esac
    shift
done

# Setup HOME dir
HOME_DIR=${HOME_DIR:-$HOME}
echo -e "HOME directory is at $HOME_DIR\n"

# Setup Toolchain dir
TC_DIR="${TC_DIR:-$HOME_DIR/tc}"
mkdir -p "$TC_DIR/linux-x86"
echo -e "Toolchain directory is at $TC_DIR\n"

SECONDS=0 # builtin bash timer
ZIPNAME="nethunter-spacewar-$(date '+%Y%m%d-%H%M').zip"
if git rev-parse --is-inside-work-tree &>/dev/null; then
    head=$(git rev-parse --short HEAD)
    ZIPNAME="${ZIPNAME%.zip}-$head.zip"
fi

CLANG_DIR="$TC_DIR/linux-x86/clang-r547379"
AK3_DIR="$HOME/AnyKernel3"
DEFCONFIG="spacewar_defconfig"

MAKE_PARAMS="O=out ARCH=arm64 CC=clang CLANG_TRIPLE=$TC_DIR/bin/llvm- LLVM=1 LLVM_IAS=1 \
	CROSS_COMPILE=aarch64-linux-gnu-"

export PATH="$CLANG_DIR/bin:$PATH"

# Regenerate defconfig, if requested
if [[ "$FLAG_REGEN_DEFCONFIG" == 'y' ]]; then
    make $MAKE_PARAMS $DEFCONFIG savedefconfig
    cp out/defconfig arch/arm64/configs/$DEFCONFIG
    echo -e "\nSuccessfully regenerated defconfig at $DEFCONFIG"
    exit
fi

# Clean build, if requested
if [[ "$FLAG_CLEAN_BUILD" == 'y' ]]; then
    echo -e "\nCleaning output folder..."
    rm -rf out
fi

mkdir -p out
make $MAKE_PARAMS $DEFCONFIG

echo -e "\nStarting compilation...\n"
make -j"$(nproc --all)" $MAKE_PARAMS || exit $?
make -j"$(nproc --all)" $MAKE_PARAMS INSTALL_MOD_PATH=modules INSTALL_MOD_STRIP=1 modules_install

kernel="out/arch/arm64/boot/Image"
dts_dir="out/arch/arm64/boot/dts/vendor/qcom"

if [[ -f "$kernel" && -d "$dts_dir" ]]; then
	echo -e "\nKernel compiled successfully! Zipping up...\n"

	if [[ -d "$AK3_DIR" ]]; then
		cp -r "$AK3_DIR" AnyKernel3
		git checkout spacewar &>/dev/null
	elif ! git clone https://github.com/kimocoder/AnyKernel3 -b spacewar; then
		echo -e "\nAnyKernel3 repo not found locally and couldn't clone from GitHub! Aborting..."
		exit 1
	fi

	KERNEL_VERSION=$(cat out/include/config/kernel.release)
	cp "$kernel" AnyKernel3
	cat "$dts_dir"/*.dtb > AnyKernel3/dtb
	python3 scripts/mkdtboimg.py create AnyKernel3/dtbo.img --page_size=4096 "$dts_dir"/*.dtbo

	mkdir -p AnyKernel3/modules/vendor/lib/modules/$KERNEL_VERSION
	cp $(find out/drivers/* -name '*.ko') AnyKernel3/modules/vendor/lib/modules/$KERNEL_VERSION/
	cp out/modules/lib/modules/$KERNEL_VERSION/modules.{alias,dep,softdep} AnyKernel3/modules/vendor/lib/modules/$KERNEL_VERSION/
	cp out/modules/lib/modules/$KERNEL_VERSION/modules.order AnyKernel3/modules/vendor/lib/modules/$KERNEL_VERSION/modules.load
	cp out/modules/lib/modules/$KERNEL_VERSION/modules.* AnyKernel3/modules/vendor/lib/modules/$KERNEL_VERSION/
	sed -i 's/\(kernel\/[^: ]*\/\)\([^: ]*\.ko\)/\/vendor\/lib\/modules\/\2/g' AnyKernel3/modules/vendor/lib/modules/$KERNEL_VERSION/modules.dep
	sed -i 's/.*\///g' AnyKernel3/modules/vendor/lib/modules/$KERNEL_VERSION/modules.load

	rm -rf out/arch/arm64/boot out/modules

	cd AnyKernel3 || exit
	zip -r9 "../$ZIPNAME" * -x .git README.md *placeholder
	cd ..

	rm -rf AnyKernel3
	echo -e "\nCompleted in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)!"
	echo "Zip: $ZIPNAME"

else
	echo -e "\nCompilation failed!"
	exit 1
fi
