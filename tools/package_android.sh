#!/usr/bin/env bash

set -e

TARGET=$1
[ -z $1 ] && TARGET=$(pwd)
echo $TARGET


if [ ! -d $TARGET ]; then
    if [[ $1 == -D* ]] || [[ $1 == --arm-arch* ]]; then
	TARGET=$(pwd)
	echo $TARGET
    else
	echo $TARGET is not a directory. please put project root of nntrainer
	exit 1
    fi
fi

pushd $TARGET

filtered_args=()
arm_arch=""
target_abi="arm64-v8a"

for arg in "$@"; do
    if [[ $arg == -D* ]]; then
	filtered_args+=("$arg")
    fi
    # Handle --arm-arch=<version> argument
    if [[ $arg == --arm-arch=* ]]; then
        arm_arch="${arg#*=}"
    fi
    # Detect -Dtarget-abi= to skip ARM config for non-ARM targets
    if [[ $arg == -Dtarget-abi=* ]]; then
        target_abi="${arg#*=}"
    fi
done

# ARM architecture config only applies to arm64-v8a target
if [[ "$target_abi" == "arm64-v8a" ]]; then
    # If --arm-arch specified, read configuration from JSON file
    if [[ -z "$arm_arch" ]]; then
        arm_arch="armv8.2-a"
    fi

    if [[ -n "$arm_arch" ]]; then
        # Convert dots to dashes for filename (e.g., armv8.2-a -> armv8-2-a)
        arch_filename=$(echo "$arm_arch" | sed 's/\./-/g')
        json_file="${TARGET}/tools/cross/android_${arch_filename}.json"
        if [[ -f "$json_file" ]]; then
            echo "Using ARM architecture config from: $json_file"
            # Read values from JSON using Python (single invocation, portable, no jq dependency)
            eval "$(python3 -c "
import json, sys
try:
    data = json.load(open('$json_file'))
    print(f'enable_fp16={data.get(\"enable_fp16\", \"True\")}')
    print(f'arm_march=\"{data.get(\"arm_march\", \"\")}\"')
except Exception as e:
    print(f'echo \"Error reading JSON: {e}\" >&2', file=sys.stderr)
    sys.exit(1)
")"
            # Add arm-arch and arm-march to meson args
            filtered_args+=("-Darm-arch=${arm_arch}")
            filtered_args+=("-Darm-march=-march=${arm_march}")
            # Handle enable_fp16 based on JSON boolean
            if [[ "$enable_fp16" == "False" ]]; then
                filtered_args+=("-Denable-fp16=false")
            fi
        else
            echo "Warning: JSON config file not found: $json_file"
            echo "Available configurations:"
            ls -1 "${TARGET}/tools/cross/"*.json 2>/dev/null || echo "  No configurations found in tools/cross/"
        fi
    fi
else
    echo "Target ABI: $target_abi (skipping ARM architecture config)"
    filtered_args+=("-Darm-arch=none")
    filtered_args+=("-Darm-march=")
    # No x86_64 prebuilt OpenBLAS available; nntrainer falls back to its
    # internal compute backend when BLAS is disabled.
    filtered_args+=("-Denable-blas=false")
fi

# Always pass target-abi to meson (if not already in filtered_args)
if ! printf '%s\n' "${filtered_args[@]}" | grep -q '^-Dtarget-abi='; then
    filtered_args+=("-Dtarget-abi=${target_abi}")
fi


if [ ! -f builddir/build.ninja ]; then
    #default value of openblas num threads is 1 for android
    #enable-tflite-interpreter=false is just temporally until ci system is stabel
    #enable-opencl=true will compile OpenCL related changes or remove this option to exclude OpenCL compilations.
  meson builddir -Dplatform=android -Dopenblas-num-threads=1 -Denable-tflite-interpreter=false -Denable-tflite-backbone=false -Denable-fp16=true -Dnntr-num-threads=4 -Dhgemm-experimental-kernel=false ${filtered_args[@]}
else
  echo "warning: $TARGET/builddir has already been taken, this script tries to reconfigure and try building"
  pushd builddir
    #default value of openblas num threads is 1 for android
    #enable-tflite-interpreter=false is just temporally until ci system is stabel  
    #enable-opencl=true will compile OpenCL related changes or remove this option to exclude OpenCL compilations.
    meson configure -Dplatform=android -Dopenblas-num-threads=1 -Denable-tflite-interpreter=false -Denable-tflite-backbone=false -Denable-fp16=true -Dnntr-num-threads=4 -Dhgemm-experimental-kernel=false ${filtered_args[@]}
    meson --wipe
  popd
fi

pushd builddir
# `ninja install` runs meson's install target for the subprojects too, which
# tries to write /usr/local/lib/libgmock.a and fails with PermissionError on a
# tree that configured googletest (i.e. any tree without -Denable-test=false).
# Only nntrainer's own artefacts belong in android_build_result, so build and
# then install with --skip-subprojects.
ninja
meson install --no-rebuild --skip-subprojects

tar -czvf $TARGET/nntrainer_for_android.tar.gz --directory=android_build_result .

popd
popd

