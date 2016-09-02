#!/bin/bash
# (for shellcheck)

IFS=$'\n'

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
ANSI_color_G="[1;32m"
ANSI_color_Y="[1;33m"
ANSI_color_B="[1;34m"
ANSI_color_M="[1;35m"
ANSI_color_W="[1;39m"
ANSI_reset="[0m"

####################################################################################################

mkdir -p "$config_dir"

umask $((666 - default_file_mode))

function AconfAddFile() {
	local file="$1" # Absolute path of file to add

	mkdir --parents "$(dirname "$system_dir"/files/"$file")"
	local link=n
	if sudo test -h "$file"
	then
		ln -s "$(sudo readlink "$file")" "$system_dir"/files/"$file"
		link=y
	else
		local size
		size=$(sudo stat "$file" --format=%s)
		if [[ $size -gt $warn_size_threshold ]]
		then
			printf "Warning: copying large file (%s bytes). Add to ignore_paths to ignore.\n" "$size"
		fi
		( sudo cat "$file" ) > "$system_dir"/files/"$file"
	fi

	{
		local mode owner group defmode
		[[ $link == y ]] && defmode=777 || defmode=$default_file_mode
		 mode="$(sudo stat --format=%a "$file")"
		owner="$(sudo stat --format=%U "$file")"
		group="$(sudo stat --format=%G "$file")"

		[[  "$mode" == "$defmode" ]] || printf  "mode\t%s\t%q\n"  "$mode" "$file"
		[[ "$owner" == root       ]] || printf "owner\t%s\t%q\n" "$owner" "$file"
		[[ "$group" == root       ]] || printf "group\t%s\t%q\n" "$group" "$file"
	} >> "$system_dir"/file-props.txt
}

# Run user configuration scripts, to collect desired state into #output_dir
function AconfCompileOutput() {
	LogEnter "Compiling user configuration...\n"

	rm -rf "$output_dir"
	mkdir "$output_dir"
	touch "$output_dir"/packages.txt
	touch "$output_dir"/foreign-packages.txt
	touch "$output_dir"/file-props.txt

	# Configuration

	typeset -Ag ignore_packages
	typeset -Ag ignore_foreign_packages

	for file in "$config_dir"/*.sh
	do
		Log "Sourcing %s...\n" "$(Color Y "$file")"
		source "$file"
	done

	LogLeave
}

# Collect system state into $system_dir
function AconfCompileSystem() {
	LogEnter "Inspecting system state...\n"

	rm -rf "$system_dir"
	mkdir "$system_dir"

	### Packages

	LogEnter "Querying package list...\n"
	pacman --query --quiet --explicit --native  | sort > "$system_dir"/packages.txt
	pacman --query --quiet --explicit --foreign | sort > "$system_dir"/foreign-packages.txt
	LogLeave

	### Files

	# Untracked files

	local ignore_args=()
	local ignore_path
	for ignore_path in "${ignore_paths[@]}"
	do
		ignore_args+=(-wholename "$ignore_path" -prune -o)
	done

	LogEnter "Searching for untracked files...\n"

	local line
	while read -r -d $'\0' line
	do
		#echo "ignore_paths+='$line' # "
		Log "Found untracked file: %s\n" "$(Color Y "$line")"
		AconfAddFile "$line"
	done < <(																				\
		comm -13 --zero-terminated															\
			 <(pacman --query --list --quiet | sed '/\/$/d' | sort --unique | tr '\n' '\0')	\
			 <(sudo find / -not \(															\
					"${ignore_args[@]}"														\
					-type d																	\
					\) -print0 |															\
					  sort --unique --zero-terminated) )

	LogLeave # Searching for untracked files

	# Modified files

	LogEnter "Searching for modified files...\n"
	while read -r line
	do
		if [[ $line =~ ^(.*):\ \'(.*)\'\ md5sum\ mismatch ]]
		then
			local package="${BASH_REMATCH[1]}"
			local file="${BASH_REMATCH[2]}"

			Log "%s: %s\n" "$(Color M "$package")" "$(Color Y "$file")" 

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
				AconfAddFile "$file"
			fi

		elif [[ $line =~ ^(.*):\  ]]
		then
			local package="${BASH_REMATCH[1]}"
			Log "%s...\r" "$(Color M "$package")"
			#echo "Now at ${BASH_REMATCH[1]}"
		fi
	done < <(sudo sh -c "stdbuf -o0 paccheck --md5sum --files --backup --noupgrade 2>&1")
	printf "\n"
	LogLeave # Searching for modified files

	LogLeave # Inspecting system state
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

	LogLeave # Collecting data
}

log_indent=:

function Log() {
	local fmt="$1"
	shift
	printf "${ANSI_clear_line}${ANSI_color_B}%s ${ANSI_color_W}${fmt}${ANSI_reset}" "$log_indent" "$@"
}

function LogEnter() {
	Log "$@"
	log_indent=$log_indent:
}

function LogLeave() {
	#[[ $# == 0 ]] || Log "Done.\n" && Log "$@"
	Log "Done.\n"
	log_indent=${log_indent::-1}
}

function Color() {
	local var="ANSI_color_$1"
	printf "%s" "${!var}"
	shift
	printf "$@"
	printf "%s" "${ANSI_color_W}"
}

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
