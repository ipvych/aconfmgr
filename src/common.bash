# common.bash

IFS=$'\n'
export LC_COLLATE=C

config_dir=config
output_dir=output
system_dir=system # Current system configuration, to be compared against the output directory
tmp_dir=tmp

warn_size_threshold=$((10*1024*1024))
default_file_mode=644

ignore_paths=(
    '/dev'
    '/home'
    '/mnt'
    '/proc'
    '/root'
    '/run'
    '/sys'
    '/tmp'
    # '/var/.updated'
    '/var/cache'
    # '/var/lib'
    # '/var/lock'
    # '/var/log'
    # '/var/spool'
)

ANSI_clear_line="[0K"
ANSI_color_R="[1;31m"
ANSI_color_G="[1;32m"
ANSI_color_Y="[1;33m"
ANSI_color_B="[1;34m"
ANSI_color_M="[1;35m"
ANSI_color_C="[1;36m"
ANSI_color_W="[1;39m"
ANSI_reset="[0m"

umask $((666 - default_file_mode))

####################################################################################################

function AconfAddFile() {
	local file="$1" # Absolute path of file to add
	found_files+=("$file")
}

function LogLeaveDirStats() {
	local dir="$1"
	Log "Finalizing...\r"
	LogLeave "Done (%s native packages, %s foreign packages, %s files).\n"	\
			 "$(Color G "$(wc -l < "$dir"/packages.txt)")"					\
			 "$(Color G "$(wc -l < "$dir"/foreign-packages.txt)")"			\
			 "$(Color G "$(find "$dir"/files -not -type d | wc -l)")"
}

# Run user configuration scripts, to collect desired state into #output_dir
function AconfCompileOutput() {
	LogEnter "Compiling user configuration...\n"

	rm -rf "$output_dir"
	mkdir --parents "$output_dir"
	mkdir "$output_dir"/files
	touch "$output_dir"/packages.txt
	touch "$output_dir"/foreign-packages.txt
	touch "$output_dir"/file-props.txt
	mkdir --parents "$config_dir"

	# Configuration

	typeset -ag ignore_packages=()
	typeset -ag ignore_foreign_packages=()

	local found=n
	for file in "$config_dir"/*.sh
	do
		if [[ -e "$file" ]]
		then
			Log "Sourcing %s...\n" "$(Color C "%q" "$file")"
			source "$file"
			found=y
		fi
	done

	if [[ $found == y ]]
	then
		LogLeaveDirStats "$output_dir"
	else
		LogLeave "Done (configuration not found).\n"
	fi
}

skip_inspection=n

# Collect system state into $system_dir
function AconfCompileSystem() {
	LogEnter "Inspecting system state...\n"

	if [[ $skip_inspection == y ]]
	then
		LogLeave "Skipped.\n"
		return
	fi

	rm -rf "$system_dir"
	mkdir "$system_dir"
	mkdir "$system_dir"/files
	touch "$system_dir"/file-props.txt

	### Packages

	LogEnter "Querying package list...\n"
	pacman --query --quiet --explicit --native  | sort | grep -vFxf <(PrintArray ignore_packages        ) > "$system_dir"/packages.txt
	pacman --query --quiet --explicit --foreign | sort | grep -vFxf <(PrintArray ignore_foreign_packages) > "$system_dir"/foreign-packages.txt
	LogLeave

	### Files

	typeset -ag found_files
	found_files=()

	# Lost files

	local ignore_args=()
	local ignore_path
	for ignore_path in "${ignore_paths[@]}"
	do
		ignore_args+=(-wholename "$ignore_path" -prune -o)
	done

	LogEnter "Searching for lost files...\n"

	local line
	(											\
		sudo find / -not \(						\
			 "${ignore_args[@]}"				\
			 -type d							\
			 \) -print0							\
			| grep								\
				  --null --null-data			\
				  --invert-match				\
				  --fixed-strings				\
				  --line-regexp					\
				  --file <(						\
				pacman --query --list --quiet	\
					| sed '/\/$/d'				\
					| sort --unique				\
			)									\
	) |											\
		while read -r -d $'\0' line
		do
			#echo "ignore_paths+='$line' # "
			#Log "%s\r" "$(Color C "%q" "$line")"

			AconfAddFile "$line"
		done

	LogLeave # Searching for lost files

	# Modified files

	LogEnter "Searching for modified files...\n"

	AconfNeedProgram paccheck pacutils y

	sudo sh -c "stdbuf -o0 paccheck --md5sum --files --backup --noupgrade 2>&1 || true" | \
		while read -r line
		do
			if [[ $line =~ ^(.*):\ \'(.*)\'\ md5sum\ mismatch ]]
			then
				local package="${BASH_REMATCH[1]}"
				local file="${BASH_REMATCH[2]}"

				local ignored=n
				for ignore_path in "${ignore_paths[@]}"
				do
					# shellcheck disable=SC2053
					if [[ "$file" == $ignore_path ]]
					then
						ignored=y
						break
					fi
				done

				if [[ $ignored == n ]]
				then
					Log "%s: %s\n" "$(Color M "%q" "$package")" "$(Color C "%q" "$file")"
					AconfAddFile "$file"
				fi

			elif [[ $line =~ ^(.*):\  ]]
			then
				local package="${BASH_REMATCH[1]}"
				Log "%s...\r" "$(Color M "%q" "$package")"
				#echo "Now at ${BASH_REMATCH[1]}"
			fi
		done
	LogLeave # Searching for modified files

	LogEnter "Reading file attributes...\n"

	typeset -a found_file_types found_file_sizes found_file_modes found_file_owners found_file_groups
	if [[ ${#found_files[*]} == 0 ]]
	then
		Log "No files found, skipping.\n"
	else
		Log "Reading file types...\n"  ;  found_file_types=($(Print0Array found_files | sudo xargs -0 stat --format=%F))
		Log "Reading file sizes...\n"  ;  found_file_sizes=($(Print0Array found_files | sudo xargs -0 stat --format=%s))
		Log "Reading file modes...\n"  ;  found_file_modes=($(Print0Array found_files | sudo xargs -0 stat --format=%a))
		Log "Reading file owners...\n" ; found_file_owners=($(Print0Array found_files | sudo xargs -0 stat --format=%U))
		Log "Reading file groups...\n" ; found_file_groups=($(Print0Array found_files | sudo xargs -0 stat --format=%G))
	fi

	LogLeave # Reading file attributes

	LogEnter "Processing found files...\n"

	local i
	for ((i=0; i<${#found_files[*]}; i++))
	do
		Log "%s/%s...\r" "$(Color G "$i")" "$(Color G "${#found_files[*]}")"

		local  file="${found_files[$i]}"
		local  type="${found_file_types[$i]}"
		local  size="${found_file_sizes[$i]}"
		local  mode="${found_file_modes[$i]}"
		local owner="${found_file_owners[$i]}"
		local group="${found_file_groups[$i]}"

		mkdir --parents "$(dirname "$system_dir"/files/"$file")"
		if [[ "$type" == "symbolic link" ]]
		then
			ln -s "$(sudo readlink "$file")" "$system_dir"/files/"$file"
		elif [[ "$type" == "regular file" || "$type" == "regular empty file" ]]
		then
			if [[ $size -gt $warn_size_threshold ]]
			then
				Log "%s: copying large file '%s' (%s bytes). Add to %s to ignore.\n" "$(Color Y "Warning")" "$(Color C "%q" "$file")" "$(Color G "$size")" "$(Color Y "ignore_paths")"
			fi
			( sudo cat "$file" ) > "$system_dir"/files/"$file"
		else
			Log "%s: Skipping file '%s' with unknown type '%s'. Add to %s to ignore.\n" "$(Color Y "Warning")" "$(Color C "%q" "$file")" "$(Color G "$type")" "$(Color Y "ignore_paths")"
			continue
		fi

		{
			local defmode
			[[ "$type" == "symbolic link" ]] && defmode=777 || defmode=$default_file_mode

			[[  "$mode" == "$defmode" ]] || printf  "mode\t%s\t%q\n"  "$mode" "$file"
			[[ "$owner" == root       ]] || printf "owner\t%s\t%q\n" "$owner" "$file"
			[[ "$group" == root       ]] || printf "group\t%s\t%q\n" "$group" "$file"
		} >> "$system_dir"/file-props.txt
	done

	LogLeave # Processing found files

	LogLeaveDirStats "$system_dir" # Inspecting system state
}

####################################################################################################

typeset -A file_property_kind_exists

# Read a file-props.txt file into an associative array.
function AconfReadFileProps() {
	local filename="$1" # Path to file-props.txt to be read
	local varname="$2"  # Name of global associative array variable to read into

	local line
	while read -r line
	do
		if [[ $line =~ ^(.*)\	(.*)\	(.*)$ ]]
		then
			local kind="${BASH_REMATCH[1]}"
			local value="${BASH_REMATCH[2]}"
			local file="${BASH_REMATCH[3]}"
			file="$(eval "printf %s $file")" # Unescape

			if [[ -z "$value" ]]
			then
				unset "$varname[\$file:\$kind]"
			else
				eval "$varname[\$file:\$kind]=\"\$value\""
			fi

			file_property_kind_exists[$kind]=y
		fi
	done < "$filename"
}

# Compare file properties.
function AconfCompareFileProps() {
	LogEnter "Comparing file properties...\n"

	typeset -ag system_only_file_props=()
	typeset -ag changed_file_props=()
	typeset -ag config_only_file_props=()

	for key in "${!system_file_props[@]}"
	do
		if [[ -z "${output_file_props[$key]+x}" ]]
		then
			system_only_file_props+=("$key")
		fi
	done

	for key in "${!system_file_props[@]}"
	do
		if [[ -n "${output_file_props[$key]+x}" && "${system_file_props[$key]}" != "${output_file_props[$key]}" ]]
		then
			changed_file_props+=("$key")
		fi
	done

	for key in "${!output_file_props[@]}"
	do
		if [[ -z "${system_file_props[$key]+x}" ]]
		then
			config_only_file_props+=("$key")
		fi
	done

	LogLeave
}

# fixed by `shopt -s lastpipe`:
# shellcheck disable=2030,2031

# Compare file information in $output_dir and $system_dir.
function AconfAnalyzeFiles() {

	#
	# Lost/modified files - diff
	#

	LogEnter "Examining files...\n"

	LogEnter "Loading data...\n"
	mkdir --parents "$tmp_dir"
	( cd "$output_dir"/files && find . -not -type d -print0 ) | cut --zero-terminated -c 3- | sort --zero-terminated > "$tmp_dir"/output-files
	( cd "$system_dir"/files && find . -not -type d -print0 ) | cut --zero-terminated -c 3- | sort --zero-terminated > "$tmp_dir"/system-files
	LogLeave

	Log "Comparing file data...\n"

	typeset -ag system_only_files=()

	( comm -13 --zero-terminated "$tmp_dir"/output-files "$tmp_dir"/system-files ) | \
		while read -r -d $'\0' file
		do
			Log "Only in system: %s\n" "$(Color C "%q" "$file")"
			system_only_files+=("$file")
		done

	typeset -ag changed_files=()

	( comm -12 --zero-terminated "$tmp_dir"/output-files "$tmp_dir"/system-files ) | \
		while read -r -d $'\0' file
		do
			if ! diff --no-dereference --brief "$output_dir"/files/"$file" "$system_dir"/files/"$file" > /dev/null
			then
				Log "Changed: %s\n" "$(Color C "%q" "$file")"
				changed_files+=("$file")
			fi
		done

	typeset -ag config_only_files=()

	( comm -23 --zero-terminated "$tmp_dir"/output-files "$tmp_dir"/system-files ) | \
		while read -r -d $'\0' file
		do
			Log "Only in config: %s\n" "$(Color C "%q" "$file")"
			config_only_files+=("$file")
		done

	LogLeave "Done (%s only in system, %s changed, %s only in config).\n"	\
			 "$(Color G "${#system_only_files[@]}")"						\
			 "$(Color G "${#changed_files[@]}")"							\
			 "$(Color G "${#config_only_files[@]}")"

	#
	# Modified file properties
	#

	LogEnter "Examining file properties...\n"

	LogEnter "Loading data...\n"
	typeset -Ag output_file_props ; AconfReadFileProps "$output_dir"/file-props.txt output_file_props
	typeset -Ag system_file_props ; AconfReadFileProps "$system_dir"/file-props.txt system_file_props
	LogLeave

	typeset -ag all_file_property_kinds
	all_file_property_kinds=($(echo "${!file_property_kind_exists[*]}" | sort))

	AconfCompareFileProps

	LogLeave "Done (%s only in system, %s changed, %s only in config).\n"	\
			 "$(Color G "${#system_only_file_props[@]}")"					\
			 "$(Color G "${#changed_file_props[@]}")"						\
			 "$(Color G "${#config_only_file_props[@]}")"
}

# Prepare configuration and system state
function AconfCompile() {
	LogEnter "Collecting data...\n"

	# Configuration

	AconfCompileOutput

	# System

	AconfCompileSystem

	# Vars

	                  packages=($(< "$output_dir"/packages.txt sort --unique))
	        installed_packages=($(< "$system_dir"/packages.txt sort --unique))

	          foreign_packages=($(< "$output_dir"/foreign-packages.txt sort --unique))
	installed_foreign_packages=($(< "$system_dir"/foreign-packages.txt sort --unique))

	AconfAnalyzeFiles

	LogLeave # Collecting data
}

####################################################################################################

pacman_opts=()
pacaur_opts=()
yaourt_opts=()
makepkg_opts=()

aur_helper=

function DetectAurHelper() {
	if [[ -n $aur_helper ]]
	then
		return
	fi

	LogEnter "Detecting AUR helper...\n"

	local helper
	for helper in pacaur yaourt makepkg
	do
		if which $helper > /dev/null
		then
			aur_helper=$helper
			LogLeave "%s... Yes\n" "$(Color C %s "$aur_helper")"
			return
		fi
		LogLeave "%s... No\n" "$(Color C %s "$aur_helper")"
	done

	Log "Can't find even makepkg!?\n"
	exit 1
}

function AconfMakePkg() {
	local package="$1"

	LogEnter "Building foreign package %s from source.\n" "$(Color M %q "$package")"
	mkdir -p "$tmp_dir"/aur/"$package"

	AconfNeedProgram git git n

	LogEnter "Cloning...\n"
	(
		cd "$tmp_dir"/aur
		git clone "https://aur.archlinux.org/$package.git"
	)
	LogLeave

	LogEnter "Checking dependencies...\n"
	local infofile infofilename
	for infofilename in .SRCINFO .AURINFO
	do
		infofile="$tmp_dir"/aur/"$package"/"$infofilename"
		if test -f "$infofile"
		then
			local depends dependency
			depends=($(grep -E $'^\t(make)?depends = ' "$infofile" | sed 's/^.* = \([a-z0-9_-]*\)\([>=].*\)\?$/\1/'))
			for dependency in "${depends[@]}"
			do
				LogEnter "%s:\n" "$(Color M %q "$dependency")"
				if pacman --query --info "$dependency" > /dev/null 2>&1
				then
					LogLeave "Already installed.\n"
				elif pacman --sync --info "$dependency" > /dev/null 2>&1
				then
					Log "Installing from repositories...\n"
					AconfInstallNative "$dependency"
					LogLeave "Installed.\n"
				else
					Log "Installing from AUR...\n"
					AconfMakePkg "$dependency"
					LogLeave "Installed.\n"
				fi
			done
		fi
	done

	LogLeave

	LogEnter "Building...\n"
	(
		cd "$tmp_dir"/aur/"$package"
		makepkg --syncdeps --install
	)
	LogLeave

	LogLeave
}

function AconfInstallNative() {
	local target_packages=("$@")
	sudo pacman --sync "${target_packages[@]}"
}

function AconfInstallForeign() {
	local target_packages=("$@")

	DetectAurHelper

	case $aur_helper in
		pacaur|yaourt)
			$aur_helper --sync --aur "${target_packages[@]}"
			;;
		makepkg)
			for package in "${target_packages[@]}"
			do
				AconfMakePkg "$package"
			done
			;;
		*)
			Log "Error: unknown AUR helper %q\n" $aur_helper
			false
			;;
	esac
}

function AconfNeedProgram() {
	local program="$1" # program that needs to be in PATH
	local package="$2" # package the program is available in
	local foreign="$3" # whether this is a foreign package

	if ! which "$program" > /dev/null 2>&1
	then
		LogEnter "Installing dependency %s:\n" "$(Color M %q "$package")"
		if [[ $foreign == y ]]
		then
			AconfInstallForeign "$package"
		else
			AconfInstallNative "$package"
		fi
		LogLeave "Installed.\n"
	fi
}

####################################################################################################

log_indent=:

function Log() {
	if [[ "$#" != 0 && -n "$1" ]]
	then
		local fmt="$1"
		shift
		printf "${ANSI_clear_line}${ANSI_color_B}%s ${ANSI_color_W}${fmt}${ANSI_reset}" "$log_indent" "$@"
	fi
}

function LogEnter() {
	Log "$@"
	log_indent=$log_indent:
}

function LogLeave() {
	if [[ $# == 0 ]]
	then
		Log "Done.\n"
	else
		Log "$@"
	fi

	log_indent=${log_indent::-1}
}

function Color() {
	local var="ANSI_color_$1"
	printf "%s" "${!var}"
	shift
	printf "$@"
	printf "%s" "${ANSI_color_W}"
}

function DisableColor() {
	ANSI_color_R=
	ANSI_color_G=
	ANSI_color_Y=
	ANSI_color_B=
	ANSI_color_M=
	ANSI_color_C=
	ANSI_color_W=
	ANSI_reset=
}

####################################################################################################

function OnError() {
	trap '' EXIT ERR

	LogEnter "%s! Stack trace:\n" "$(Color R "Fatal error")"

	local frame=0 str
	while str=$(caller $frame)
	do
		if [[ $str =~ ^([^\ ]*)\ ([^\ ]*)\ (.*)$ ]]
		then
			Log "%s:%s [%s]\n" "$(Color C "%q" "${BASH_REMATCH[3]}")" "$(Color G "%q" "${BASH_REMATCH[1]}")" "$(Color Y "%q" "${BASH_REMATCH[2]}")"
		else
			Log "%s\n" "$str"
		fi

		frame=$((frame+1))
	done
}
trap OnError EXIT ERR

function Exit() {
	trap '' EXIT ERR
	exit "${1:-0}"
}

####################################################################################################

# Print an array, one element per line (assuming IFS starts with \n).
# Work-around for Bash considering it an error to expand an empty array.
function PrintArray() {
	local name="$1" # Name of the global variable containing the array
	local size

	size="$(eval "echo \${#$name""[*]}")"
	if [[ $size != 0 ]]
	then
		eval "echo \"\${$name[*]}\""
	fi
}

# Ditto, but terminate elements with a NUL.
function Print0Array() {
	local name="$1" # Name of the global variable containing the array

	eval "$(cat <<EOF
	if [[ \${#$name[*]} != 0 ]]
	then
		local item
		for item in "\${${name}[@]}"
		do
			printf "%s\0" "\$item"
		done
	fi
EOF
)"
}
