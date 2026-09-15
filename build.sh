#!/usr/bin/env bash
# Theta build helper
#   ./build.sh           → rootful .deb
#   ./build.sh rootless  → rootless .deb
#   ./build.sh sideload  → inject into input/Payload → output/Instagram_patched.ipa
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

make_cmd=make
if command -v gmake &>/dev/null; then
	make_cmd=gmake
fi

export COPYFILE_DISABLE=1

MODE="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
# Default = rootful
if [[ -z "$MODE" || "$MODE" == "rootful" ]]; then
	MODE="rootful"
fi

usage() {
	cat <<'EOF'
Usage: ./build.sh [rootful|rootless|sideload]

  (no args) / rootful   Build a rootful jailbreak package
  rootless              Build a rootless jailbreak package
  sideload              Build SIDELOAD=1 dylibs (Theta + ThetaNSE) and inject
                        Theta into the app and ThetaNSE into the notification
                        service extension (required for decrypted banners)

Sideload expects a decrypted Instagram IPA unpacked as:
  input/Payload/Instagram.app/...

Output:
  packages/*.deb                (rootful / rootless)
  output/Instagram_patched.ipa  (sideload)
EOF
}

if [[ "$MODE" == "-h" || "$MODE" == "--help" || "$MODE" == "help" ]]; then
	usage
	exit 0
fi

strip_entitlements() {
	local target="$1"
	[[ -f "$target" ]] || return 0
	/usr/bin/codesign --remove-signature "$target" 2>/dev/null || true
	/usr/bin/codesign -f -s - "$target" 2>/dev/null || true
}

plist_print() {
	local plist="$1" key="$2"
	/usr/libexec/PlistBuddy -c "Print ${key}" "$plist" 2>/dev/null || true
}

binary_already_loads() {
	local bin="$1" needle="$2"
	if command -v otool &>/dev/null; then
		otool -L "$bin" 2>/dev/null | grep -q "$needle" && return 0
	fi
	return 1
}

macho_filetype() {
	local path="$1"
	[[ -f "$path" ]] || return 1
	# Skip otool's column-header line (it also contains the word "filetype").
	otool -h "$path" 2>/dev/null | awk '$1 ~ /^0x/{print $5; exit}'
}

is_macho_dylib() {
	local path="$1" ft
	[[ -f "$path" ]] || return 1
	[[ "$path" == *.dSYM/* ]] && return 1
	ft="$(macho_filetype "$path")"
	[[ "$ft" == "6" ]]
}

install_and_verify_dylib() {
	local src="$1" dest="$2" id_path="$3"
	if ! is_macho_dylib "$src"; then
		echo "[Build] ERROR: refusing to copy non-dylib: $src"
		file "$src" || true
		otool -h "$src" 2>/dev/null | head -8 || true
		exit 1
	fi
	echo "[Build] Copy $(basename "$dest") from $src ($(file -b "$src"))"
	cp -f "$src" "$dest"
	if command -v install_name_tool &>/dev/null && [[ -n "$id_path" ]]; then
		install_name_tool -id "$id_path" "$dest" 2>/dev/null || true
	fi
	shift 3
	local old new
	while [[ $# -ge 2 ]]; do
		old="$1"; new="$2"; shift 2
		install_name_tool -change "$old" "$new" "$dest" 2>/dev/null || true
	done
	strip_entitlements "$dest"
	if ! is_macho_dylib "$dest"; then
		echo "[Build] ERROR: $dest is not MH_DYLIB after install"
		file "$dest" || true
		exit 1
	fi
}

find_built_dylib() {
	local name="$1"
	local cand
	for cand in \
		"$SCRIPT_DIR/.theos/obj/${name}" \
		"$SCRIPT_DIR/.theos/obj/debug/${name}" \
		"$SCRIPT_DIR/.theos/obj/arm64/${name}" \
		"$SCRIPT_DIR/.theos/_/Library/MobileSubstrate/DynamicLibraries/${name}" \
		"$SCRIPT_DIR/.theos/_/usr/lib/TweakInject/${name}" \
		"$SCRIPT_DIR/.theos/_/usr/lib/${name}"
	do
		if is_macho_dylib "$cand"; then
			printf '%s\n' "$cand"
			return 0
		fi
	done
	if [[ -d "$SCRIPT_DIR/.theos" ]]; then
		while IFS= read -r cand; do
			[[ -n "$cand" ]] || continue
			if is_macho_dylib "$cand"; then
				printf '%s\n' "$cand"
				return 0
			fi
		done < <(find "$SCRIPT_DIR/.theos" -name "$name" -type f ! -path '*.dSYM/*' 2>/dev/null)
	fi
	return 1
}

compile_theta_nse_clang() {
	local src="$SCRIPT_DIR/Source/SideloadNSE/ThetaNSE.m"
	local out="$SCRIPT_DIR/.theos/obj/ThetaNSE.dylib"
	local sdk
	[[ -f "$src" ]] || return 1
	mkdir -p "$(dirname "$out")"
	sdk="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
	[[ -n "$sdk" ]] || return 1
	echo "[Build] Compiling ThetaNSE.dylib with clang..."
	xcrun -sdk iphoneos clang -arch arm64 -isysroot "$sdk" \
		-miphoneos-version-min=14.0 \
		-fobjc-arc -fPIC -shared -fvisibility=hidden \
		-I"$SCRIPT_DIR" \
		-framework Foundation -framework Security \
		-o "$out" "$src" "$SCRIPT_DIR/Source/SideloadNSE/ThetaHPKEKeyFile.m" "$SCRIPT_DIR/fishhook.c"
}

# Instagram encrypts APNs; InstagramNotificationExtension decrypts them.
# Inject the tiny ThetaNSE remap dylib (full Theta.dylib is too big for NSE jetsam).
inject_theta_nse() {
	local app_dir="$1"
	local nse_src="$2"
	local plugins="$app_dir/PlugIns"
	local injected=0

	if [[ ! -f "$nse_src" ]]; then
		echo "[Build] ERROR: ThetaNSE.dylib not found at $nse_src"
		exit 1
	fi
	if [[ ! -d "$plugins" ]]; then
		echo "[Build] WARNING: no PlugIns — rich notifications will stay generic"
		return 0
	fi

	# Resigners sign *.framework under Frameworks/; they often skip loose
	# .dylib files and then the NSE dies on a required LC_LOAD (no logs).
	# The NSE already has rpath @executable_path/Frameworks and ../../Frameworks.
	local fw_id="@rpath/ThetaNSE.framework/ThetaNSE"

	local appex plist point exe bin patched
	while IFS= read -r -d '' appex; do
		plist="$appex/Info.plist"
		[[ -f "$plist" ]] || continue
		point="$(plist_print "$plist" ":NSExtension:NSExtensionPointIdentifier")"
		[[ "$point" == "com.apple.usernotifications.service" ]] || continue

		exe="$(plist_print "$plist" ":CFBundleExecutable")"
		if [[ -z "$exe" ]]; then
			exe="$(basename "$appex" .appex)"
		fi
		bin="$appex/$exe"
		if [[ ! -f "$bin" ]]; then
			echo "[Build] WARNING: missing NSE binary $bin"
			continue
		fi

		mkdir -p "$appex/Frameworks"
		stage_theta_nse_framework "$nse_src" "$appex/Frameworks/ThetaNSE.framework" "$fw_id"
		if [[ -d "$app_dir/CydiaSubstrate.framework" ]]; then
			rm -rf "$appex/Frameworks/CydiaSubstrate.framework"
			rsync -a "$app_dir/CydiaSubstrate.framework/" "$appex/Frameworks/CydiaSubstrate.framework/"
			if [[ -f "$appex/Frameworks/CydiaSubstrate.framework/CydiaSubstrate" ]]; then
				install_name_tool -id "@rpath/CydiaSubstrate.framework/CydiaSubstrate" \
					"$appex/Frameworks/CydiaSubstrate.framework/CydiaSubstrate" 2>/dev/null || true
				strip_entitlements "$appex/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
			fi
		fi

		local old
		for old in \
			"@executable_path/../../ThetaNSE.dylib" \
			"@executable_path/ThetaNSE.dylib"
		do
			if binary_already_loads "$bin" "$old"; then
				echo "[Build] Rewriting NSE load path $old → $fw_id"
				install_name_tool -change "$old" "$fw_id" "$bin" 2>/dev/null || true
			fi
		done

		if ! binary_already_loads "$bin" "ThetaNSE.framework"; then
			patched="$appex/${exe}_patched"
			cp -f "$bin" "$patched"
			echo "[Build] Injecting $fw_id (weak) into $(basename "$appex")..."
			if ! "$SCRIPT_DIR/tools/insert_dylib" --weak "$fw_id" "$patched" --all-yes --inplace; then
				rm -f "$patched"
				echo "[Build] ERROR: insert_dylib failed for $(basename "$appex")"
				exit 1
			fi
			rm -f "$bin"
			cp -f "$patched" "$bin"
			rm -f "$patched"
			chmod +x "$bin"
		fi
		strip_entitlements "$bin"
		if ! binary_already_loads "$bin" "ThetaNSE.framework"; then
			echo "[Build] ERROR: $(basename "$appex") does not list ThetaNSE.framework after inject"
			exit 1
		fi
		injected=1
	done < <(find "$plugins" -maxdepth 1 -type d -name "*.appex" -print0)

	if [[ "$injected" -eq 0 ]]; then
		echo "[Build] ERROR: no com.apple.usernotifications.service extension found"
		echo "[Build] Keep PlugIns/InstagramNotificationExtension.appex in the IPA"
		exit 1
	fi
}

stage_theta_nse_framework() {
	local src="$1" dest="$2" id_path="$3"
	mkdir -p "$dest"
	install_and_verify_dylib "$src" "$dest/ThetaNSE" "$id_path"
	cat > "$dest/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>ThetaNSE</string>
	<key>CFBundleIdentifier</key>
	<string>com.theta.nse</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>ThetaNSE</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>MinimumOSVersion</key>
	<string>14.0</string>
</dict>
</plist>
PLIST
}

ensure_insert_dylib() {
	local src="$SCRIPT_DIR/tools/insert_dylib.c"
	local bin="$SCRIPT_DIR/tools/insert_dylib"
	if [[ ! -f "$src" ]]; then
		echo "[Build] ERROR: missing $src"
		exit 1
	fi
	if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
		echo "[Build] Compiling insert_dylib..."
		cc -O2 -o "$bin" "$src"
	fi
}

stage_substrate_framework() {
	# Copies CydiaSubstrate.framework into $1 (Instagram.app root)
	local app_dir="$1"
	local dest="$app_dir/CydiaSubstrate.framework"
	local extract_py="$SCRIPT_DIR/scripts/extract-substrate-from-deb.py"
	local cached="$SCRIPT_DIR/third_party/CydiaSubstrate.framework"

	copy_fw() {
		local src="$1"
		[[ -d "$src" ]] || return 1
		[[ -f "$src/CydiaSubstrate" || -f "$src/CydiaSubstrate.dylib" ]] || return 1
		rm -rf "$dest"
		mkdir -p "$dest"
		rsync -a "$src/" "$dest/"
		if [[ ! -f "$dest/CydiaSubstrate" && -f "$dest/CydiaSubstrate.dylib" ]]; then
			cp -f "$dest/CydiaSubstrate.dylib" "$dest/CydiaSubstrate"
		fi
		if command -v install_name_tool &>/dev/null; then
			install_name_tool -id "@executable_path/CydiaSubstrate.framework/CydiaSubstrate" "$dest/CydiaSubstrate" 2>/dev/null || true
		fi
		# Also stage under Frameworks/ so the NSE can dlopen via its existing rpath.
		if [[ -n "${app_dir:-}" ]]; then
			mkdir -p "$app_dir/Frameworks"
			rm -rf "$app_dir/Frameworks/CydiaSubstrate.framework"
			rsync -a "$dest/" "$app_dir/Frameworks/CydiaSubstrate.framework/"
			install_name_tool -id "@rpath/CydiaSubstrate.framework/CydiaSubstrate" \
				"$app_dir/Frameworks/CydiaSubstrate.framework/CydiaSubstrate" 2>/dev/null || true
		fi
		strip_entitlements "$dest/CydiaSubstrate"
		echo "[Build] Staged CydiaSubstrate.framework → $dest"
		return 0
	}

	if [[ -n "${SUBSTRATE_FRAMEWORK_PATH:-}" ]] && copy_fw "$SUBSTRATE_FRAMEWORK_PATH"; then
		return 0
	fi
	if copy_fw "$cached"; then
		return 0
	fi

	# Search nearby IPA unpacks / Sideloadly cache
	local hit
	while IFS= read -r hit; do
		[[ -n "$hit" ]] || continue
		if copy_fw "$(dirname "$hit")"; then
			mkdir -p "$cached"
			rsync -a "$dest/" "$cached/"
			return 0
		fi
	done < <(find "$HOME/Library/Application Support/Sideloadly" "$HOME/Downloads" "$HOME/Desktop" "$SCRIPT_DIR/packages" \
		-path "*/CydiaSubstrate.framework/CydiaSubstrate" -type f 2>/dev/null | head -5)

	if [[ -f "$extract_py" ]]; then
		echo "[Build] Fetching CydiaSubstrate from mobilesubstrate .deb..."
		mkdir -p "$cached"
		if python3 "$extract_py" "$cached"; then
			copy_fw "$cached" && return 0
		fi
	fi

	echo "[Build] ERROR: could not stage CydiaSubstrate.framework"
	echo "[Build] Set SUBSTRATE_FRAMEWORK_PATH or place it at third_party/CydiaSubstrate.framework"
	exit 1
}

build_jailbreak() {
	local label="$1"
	$make_cmd clean
	if [[ "$label" == "rootless" ]]; then
		echo "[Build] Building rootless package..."
		$make_cmd package ROOTLESS=1
	else
		echo "[Build] Building rootful package..."
		$make_cmd package
	fi
	echo "[Build] Done. Packages in ./packages/"
	ls -la packages/*.deb 2>/dev/null || true
}

resolve_app_binary() {
	# Prints: <app_dir>|<binary_basename>
	local payload_dir="$1"
	local app_dir binary_name input_bin plist

	app_dir="$(find "$payload_dir" -maxdepth 1 -type d -name "*.app" | head -1 || true)"
	if [[ -z "${app_dir}" ]]; then
		echo "[Build] ERROR: no .app found under $payload_dir" >&2
		return 1
	fi

	binary_name="$(basename "$app_dir")"
	binary_name="${binary_name%.app}"

	plist="$app_dir/Info.plist"
	if [[ -f "$plist" ]] && command -v /usr/libexec/PlistBuddy &>/dev/null; then
		local exe
		exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
		if [[ -n "${exe}" ]]; then
			binary_name="$exe"
		fi
	fi

	input_bin="$app_dir/$binary_name"
	if [[ ! -f "$input_bin" ]]; then
		input_bin="$(find "$app_dir" -maxdepth 1 -type f -perm -111 ! -name '.*' | head -1 || true)"
	fi
	if [[ -z "${input_bin}" || ! -f "$input_bin" ]]; then
		echo "[Build] ERROR: could not find main binary inside $(basename "$app_dir")" >&2
		return 1
	fi

	binary_name="$(basename "$input_bin")"
	printf '%s|%s\n' "$app_dir" "$binary_name"
}

build_sideload() {
	local input_payload="$SCRIPT_DIR/input/Payload"
	local output_dir="$SCRIPT_DIR/output"
	local output_payload="$output_dir/Payload"
	local ipa_out="$output_dir/Instagram_patched.ipa"
	local app_dir="" app_name="" binary_name="" out_app="" out_bin="" patched="" dylib_src="" nse_src=""

	if [[ ! -d "$input_payload" ]]; then
		echo "[Build] ERROR: missing input/Payload"
		echo "[Build] Unpack a decrypted Instagram IPA so you have:"
		echo "[Build]   input/Payload/Instagram.app/Instagram"
		exit 1
	fi

	local resolved
	resolved="$(resolve_app_binary "$input_payload")" || exit 1
	app_dir="${resolved%%|*}"
	binary_name="${resolved##*|}"
	app_name="$(basename "$app_dir")"

	echo "[Build] App: $app_name  binary: $binary_name"
	echo "[Build] Building sideload dylib..."
	$make_cmd clean
	$make_cmd package SIDELOAD=1

	local dylib_src nse_src
	dylib_src="$(find_built_dylib Theta.dylib)" || {
		echo "[Build] ERROR: Theta.dylib not found after build"
		exit 1
	}
	nse_src="$(find_built_dylib ThetaNSE.dylib || true)"
	if [[ -z "$nse_src" ]]; then
		compile_theta_nse_clang || {
			echo "[Build] ERROR: ThetaNSE.dylib not found after SIDELOAD build"
			exit 1
		}
		nse_src="$(find_built_dylib ThetaNSE.dylib)" || {
			echo "[Build] ERROR: ThetaNSE.dylib not found after clang fallback"
			exit 1
		}
	fi

	ensure_insert_dylib

	echo "[Build] Preparing output/Payload from input/Payload..."
	rm -rf "$output_dir"
	mkdir -p "$output_dir"
	cp -f -R "$input_payload" "$output_payload"

	out_app="$output_payload/$app_name"
	out_bin="$out_app/$binary_name"
	patched="$output_dir/${binary_name}_patched"

	if [[ ! -f "$out_bin" ]]; then
		echo "[Build] ERROR: missing $out_bin"
		exit 1
	fi

	cp -f "$out_bin" "$patched"
	echo "[Build] Injecting @executable_path/Theta.dylib into ${binary_name}..."
	"$SCRIPT_DIR/tools/insert_dylib" "@executable_path/Theta.dylib" "$patched" --all-yes --inplace

	rm -f "$out_bin"
	cp -f "$patched" "$out_bin"
	chmod +x "$out_bin"
	strip_entitlements "$out_bin"

	echo "[Build] Installing Theta.dylib into app root..."
	install_and_verify_dylib "$dylib_src" "$out_app/Theta.dylib" \
		"@executable_path/Theta.dylib" \
		"/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate" \
		"@executable_path/CydiaSubstrate.framework/CydiaSubstrate" \
		"@rpath/CydiaSubstrate.framework/CydiaSubstrate" \
		"@executable_path/CydiaSubstrate.framework/CydiaSubstrate"

	stage_substrate_framework "$out_app"

	inject_theta_nse "$out_app" "$nse_src"

	# Optional resources / ffmpeg (best-effort)
	if [[ -d "$SCRIPT_DIR/ThetaResources.bundle" ]]; then
		rm -rf "$out_app/ThetaResources.bundle"
		cp -f -R "$SCRIPT_DIR/ThetaResources.bundle" "$out_app/ThetaResources.bundle"
	fi
	local ffmpeg_src="$SCRIPT_DIR/layout/Library/Application Support/ffmpeg.framework"
	if [[ -d "$ffmpeg_src" ]]; then
		echo "[Build] Embedding ffmpeg.framework..."
		rm -rf "$out_app/ffmpeg.framework"
		# Follow symlink if present
		cp -f -R "$ffmpeg_src" "$out_app/ffmpeg.framework"
	fi

	# Housekeeping
	find "$output_payload" -name ".DS_Store" -delete 2>/dev/null || true
	xattr -rc "$output_payload" 2>/dev/null || true

	echo "[Build] Zipping IPA..."
	rm -f "$ipa_out"
	(
		cd "$output_dir"
		zip -9 -r "Instagram_patched.ipa" Payload
	)

	echo "[Build] Sideload IPA ready:"
	echo "         $ipa_out"
	ls -lh "$ipa_out"
}

case "$MODE" in
	rootful)
		build_jailbreak rootful
		;;
	rootless)
		build_jailbreak rootless
		;;
	sideload)
		build_sideload
		;;
	*)
		echo "[Build] Invalid mode: $MODE"
		usage
		exit 1
		;;
esac
