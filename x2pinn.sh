#!/bin/bash
#
#  Copyright (c) 2024 Torben Bruchhaus
#  File: x2pinn.sh
#  Revision 2
#
#  x2pinn is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  x2pinn is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with x2pinn.  If not, see <http://www.gnu.org/licenses/>.

# Error codes
E_NOT_ROOT=1
E_BAD_ARG=2
E_MISSING_FILE=3
E_CMD_NONZERO=4
E_MNT_EXISTS=5
E_BAD_KEY=6
E_ARCHIVE_NAME=7
E_UNCHANGED=8
E_NO_DOWNLOAD=9
E_BAD_ARCHIVE=10
E_BAD_FDISK=11
E_NO_PART_CFG=12

# Make sure that the script is running as root
if [ "$(whoami)" != "root" ]; then
  echo "This script must be run as root"
  exit $E_NOT_ROOT
fi

# Check if bsdtar if available
if [ -z "$(which bsdtar)" ]; then
  echo "The script requires 'bsdtar' which is part of package 'libarchive-tools'"
  exit $E_MISSING_FILE
fi
  
# Command line arguments
use_debug=0
use_check=1
use_tar=1
use_xz=1
use_cleanup=0
fdisk_only=0

for arg in $@; do
  case $arg in
    --cleanup)    use_cleanup=1;;
    --debug)      use_debug=1;;
    --fdisk-only) fdisk_only=1;;
    --no-check)   use_check=0;;
    --no-tar)     use_tar=0;;
    --no-xz)      use_xz=0;;
    *)
      echo "Unknown argument '$arg'!"
      exit $E_BAD_ARG
      ;;
  esac
done

function debug_print() {
  # Only print if debug is enabled
  if [ $use_debug -eq 1 ]; then echo -e "\033[0;34m$1\033[0m"; fi
}

debug_print "use_debug='$use_debug'"
debug_print "use_check='$use_check'"
debug_print "use_tar='$use_tar'"
debug_print "use_xz='$use_xz'"
debug_print "fdisk_only='$fdisk_only'"

# Directory used as mount point for partitions, do NOT change this without understanding the mount procedure!!!
mount_dir="mnt"
if [ -d $mount_dir ] && [ -n "$(ls -A $mount_dir)" ]; then
  echo "Directory '$mount_dir' already exists and is not empty"
  exit $E_MNT_EXISTS
fi

# Checks exit status of a process and exits the script if non-sero
function check_status() {
  if [ $2 -ne 0 ]; then
    echo "Command '$1' failed with exit status $2"
    if [ -z "$3" ]; then exit $E_CMD_NONZERO; else exit $3; fi
  fi
}

# Used to set ownership for files and dirs to $SUDO_USER
function do_chown() {
  if [ $SUDO_UID -ne 0 ] && [ $SUDO_GID -ne 0 ]; then
    if [ -d "$1" ]; then
      chown -R $SUDO_UID":"$SUDO_GID "$1"
    elif [ -f "$1" ]; then
      chown $SUDO_UID":"$SUDO_GID "$1"
    fi
    #check_status "chown" $?
  fi
}

# Checks for existence of a required file
function must_exist() {
  for arg in $@; do
    if [ -f "$arg" ]; then return 0; fi;
  done
  echo "File '$1' was not found!"
  exit $E_MISSING_FILE
}

# Declare name of project file
project_file="x2pinn.txt"

# Declare name for extracted image file
extract_name="extracted.img"

# Verify existence of project file
must_exist "$project_file"

# Load project file and ignore lines starting with '#'
echo "Loading project file '$project_file'.."
project=$(grep -v ^"#" "$project_file")

# Grab global variables from the project
import=""

archive=""
common=""
download=""
output=""

cp_slides=""
addsize=0
parts=""
partcfg=()
tarballs=""

base_url=""
checksum=sha512sum
release_date=""

json_fields=""

# RegEx used to trim the ends of a string
sed_trim='s/^[ \t]*//;s/[ \t]*$//'

# RegEx used to validate a number / integer
sed_numval='s/^([0-9]{1,})$/\1/p'

# Used to split a string by a delimiter
function split_string() {
  local delim=$2
  if [ -z "$delim" ]; then delim="="; fi
  split1=$(echo "${1%%$delim*}" | sed "$sed_trim")
  split2=$(echo "${1#*$delim}" | sed "$sed_trim")
}

function parse_project() {

  local src=$1
  
  while [ -n "$src" ]; do
    
    local line=$(echo "$src" | head -n 1 | sed "$sed_trim")
    src=$(echo "$src" | tail -n +2)
    
    #echo "$line"
    
    if [ -n "$line" ]; then
    
      split_string "$line"
      #echo "split1='$split1', split2='$split2'"
      
      case $split1 in
        archive)
          archive=$split2
          ;;
        common)
          common=$split2
          ;;
        download)
          download=$split2
          ;;
        import)
          if [ $2 -eq 1 ] && [ -f "$split2" ]; then
            import=$(grep -v ^"#" "$split2")
            return 0
          fi
          ;;
        output)
          output=$split2
          ;;

        addsize)
          addsize=$split2
          ;;
        copy_slides)
          cp_slides=$split2
          ;;
        part*)
          line=${line:4}   # Remove first 4
          split_string "$line"
          parts="$parts$split1 "
          debug_print "partcfg='$line'"
          partcfg+=("$line") # Add to array
          ;;
        sector)
          echo "Field 'sector' is deprecated and should no longer be used."
          ;;
        tarballs)
          tarballs=$split2
          ;;

        base_url)
          base_url=$split2
          ;;
        checksum)
          checksum=$split2
          ;;

        *)
          tok=${split1::5}
          if [ "$tok" = "list:" ] || [ "$tok" = "both:" ] || [ "${split1::3}" = "os:" ]; then
            if [ "${split1:5}" = "release_date" ]; then release_date=$(printf $split2 | xargs); fi
            json_fields="$json_fields$line\n"
          else
            echo "Project contains invalid field '$split1' in line '$line'"
            exit $E_BAD_KEY
          fi
          ;;
      esac
      
    fi
    
  done

}

# Load project and import if specified
parse_project "$project" 1
if [ -n "$import" ]; then
  parse_project "$import" 0
  parse_project "$project" 0
fi

# If archive is undeclared, grab it from download and verify
if [ -z "$archive" ]; then
  archive=${download##*/} # Get after last /
  archive=${archive%\?*}  # Get before first ?
  if [ -z "$archive" ]; then
    echo "Field 'archive' is empty an could not be extracted from '$download'"
    exit $E_ARCHIVE_NAME
  fi
fi

# Did we get any partitions?
if [ -n "$parts" ]; then parts=${parts::-1} # Remove last space
else
  echo "No partitions has been specified"
  exit $E_NO_PART_CFG
fi

# If tarballs is undefined, create it from parts
if [ -z "$tarballs" ]; then
  for tok in ${parts[@]}; do
    tarballs="$tarballs @$tok"
  done
  tarballs=${tarballs:1}
fi

# If output is undeclared, use "os" and get an absolute path
if [ -z "$output" ]; then output="os"; fi
output=$(realpath -ms "$output")

debug_print "archive='$archive'"
debug_print "common='$common'"
debug_print "download='$download'"
debug_print "output='$output'"

debug_print "addsize='$addsize'"
debug_print "cp_slides='$cp_slides'"
debug_print "parts='$parts'"
#debug_print "sector='$sector'"
debug_print "tarballs='$tarballs'"

debug_print "base_url='$base_url'"
debug_print "checksum='$checksum'"
debug_print "release_date='$release_date'"
debug_print "$json_fields"

# Check for release date change
check_file="$project_file"".rd"
if [ $use_check -eq 1 ] && [ -f "$check_file" ]; then
  if [ "$release_date" = "$(cat $check_file)" ]; then
    echo "Release date has not changed, bye.."
    exit $E_UNCHANGED
  fi
fi

# Used to locate required resources
function find_rc() {
  if [ ! -f "$1" ] && [ ! -d "$1" ] && [ -d "$common" ]; then
    local fn=$(realpath --relative-to=. -ms "$common/$1")
    if [ -f "$fn" ] || [ -d "$fn" ]; then
      if [ ${fn:(-1)} = "/" ]; then fn=${fn::-1}; fi
      echo "$fn"
      return 0
    fi
  fi
  echo "$1"
}

# Find files
partitions=$(find_rc "partitions.json")
part_setup=$(find_rc "partition_setup.sh")
slides_dir=$(find_rc "slides_vga")
rele_notes=$(find_rc "release_notes.txt")

# Debug
debug_print "partitions='$partitions'"
debug_print "part_setup='$part_setup'"
debug_print "slides_dir='$slides_dir'"

# Verify existence of required files
must_exist "$partitions"
must_exist "$part_setup" "$output/$part_setup"

# If marketing.tar does not exists in src or dst, try to create it from "slides_vga"
slides_tar="marketing.tar"
if [ -d "$slides_dir" ] && [ ! -f "$slides_tar" ] && [ ! -f "$output/$slides_tar" ]; then
  tmp=$(realpath --relative-to=. -ms "$slides_dir/../$slides_tar")
  if [ ! -f "$tmp" ]; then
    echo "Creating '$tmp' from '$slides_dir'.."
    bsdtar --numeric-owner --format gnutar -cpvf "$tmp" "$slides_dir" 2> /dev/null
    check_status "bsdtar" $?
  fi
  slides_tar=$tmp
fi

debug_print "slides_tar='$slides_tar'"
must_exist "$slides_tar" "$output/marketing.tar"

# Used to determine whether we are handling a block device
blockdev=0

# Are we handling a block device?
if [ "${archive:0:5}" = "/dev/" ]; then

  if [ -e "$archive" ]; then
    
    extract_name=$archive
    blockdev=1
    
  else
    
    echo "The block device '$archive' does not exist!"
    exit $E_MISSING_FILE
    
  fi
  
elif [ -f "$extract_name" ]; then

  # No need to download and/or extract
  echo "Using extracted image '$extract_name'.."
  
else

  # If the archive does not already exist, download it..
  if [ -f "$archive" ]; then
    
    echo "Archive '$archive' already exists, not downloading"
    
  elif [ -z "$download" ]; then

    echo "Field 'download' is missing, archive cannot be downloaded!"
    exit $E_NO_DOWNLOAD
    
  else
    
    echo "Downloading archive '$archive' from '$download'.."
    wget -c -O "$archive".part "$download"
    check_status "wget" $?
    mv "$archive".part "$archive"
    do_chown "$archive"

  fi

  # Extract the archive..
  ext=${archive##*.}
  debug_print "Archive extension: '$ext'"
  echo "Extracting archive '$archive' as '$extract_name'.."

  case $ext in
    gz)
      gunzip -c "$archive" > "$extract_name"
      check_status "gunzip" $?
      ;;
    xz)
      unxz -c "$archive" > "$extract_name"
      check_status "unxz" $?
      ;;
    lzma)
      unlzma -c "$archive" > "$extract_name"
      check_status "unlzma" $?
      ;;
    7z)
      7z e -so "$archive" > "$extract_name"
      check_status "7z" $?
      ;;
    zip)
      unzip -p "$archive" > "$extract_name"
      check_status "unzip" $?
      ;;
    *)
      echo "Unsupported archive type: '$ext'"
      exit $E_BAD_ARCHIVE
      ;;
  esac
  
  do_chown "$extract_name"

fi

echo "Examining the extracted image.."
if [ $fdisk_only -eq 1 ]; then
  fdisk_out=$(fdisk -l "$extract_name")
  echo "$fdisk_out"
  echo "fdisk only selected, bye bye.."
  exit
else
  fdisk_out=$(fdisk -l --bytes -o Device,Start,Sectors,Size "$extract_name")
  check_status "fdisk" $?
  debug_print "$fdisk_out"
fi

# Extract sector size if undefined
#if [ -z "$sector" ]; then
  #sector=$(echo "$fdisk_out" | grep "Sector size" | awk '{print $(NF-1)}')
  #sector=$(echo "$fdisk_out" | sed -En 's/.*([ ][0-9]{1,}[ ]\*{1}[ ][0-9]{1,}[ ]=[ ])([0-9]{1,}).*/\2/p')
  #debug_print "Extracted sector size is: $sector"
  #if [ -z "$sector" ]; then
    #echo "Unable to extract sector size, please define it with 'sector=size' in the project"
    #exit $E_NO_SECTOR
  #fi
#fi

# Replace one string with another string in a string
function string_replace() {
  # replaced=$(string_replace "source" "find" "substitute")
  local sedsafe=$3
  if [ -n "$sedsafe" ]; then sedsafe=$(echo "$3" | sed -e 's/[\/&]/\\&/g'); fi
  local result=$(echo "$1" | sed -e "s/$2/$sedsafe/g")
  echo "$result"
}

# Get checksum for a file
function get_checksum() {
  local result=$($checksum -b "$1" | awk '{print $1}')
  check_status "$checksum|awk" $?
  echo "$result"
}

# Used to set some variables according to the value specified by part[id]=??? in the project..
function get_partcfg() {

  p_nosock=0
  p_getfacl=0
  p_linux=0
  p_name=""
  p_abs=0
  p_add=0
  p_id=$1
  
  debug_print "get_partcfg for $p_id"
  
  for pcfg in "${partcfg[@]}"; do
    
    split_string "$pcfg"
    
    if [ "$split1" = "$p_id" ]; then
    
      read -ra acfg <<< "$split2"
      
      for tok in ${acfg[@]}; do
      
        if [ -z "$p_name" ]; then p_name=$tok
        elif [ $tok = "nosock" ]; then p_nosock=1
        elif [ $tok = "getfacl" ]; then p_getfacl=1
        #elif [ $tok = "linux" ]; then p_linux=1
        elif [ ${tok:0:1} = "+" ]; then p_add=${tok:1}
        elif [ ${tok:0:1} = "=" ]; then p_abs=${tok:1}
        else
          echo "Unknown partition setting: '$tok'!"
          exit $E_NO_PART_CFG
        fi
        
      done
      
      debug_print "p_name='$p_name'"
      debug_print "p_nosock='$p_nosock'"
      debug_print "p_getfacl='$p_getfacl'"
      debug_print "p_abs='$p_add'"
      debug_print "p_add='$p_add'"

      return 1
      
    fi
    
  done
  
  echo "Unable to get partition settings for '$partid'!"
  exit $E_NO_PART_CFG
  
}

# Used to establish the sizes of the project
download_size=0
nominal_size=0

# Load partitions.json
partitions=$(cat "$partitions")

# Create output dir, if not exists
if [ ! -d "$output" ]; then
  echo "Creating output directory.."
  su -c "mkdir -p '$output'" $SUDO_USER
  check_status "mkdir" $?
fi

# Create mount point, if not exists
if [ ! -d "$mount_dir" ]; then
  echo "Creating mount point.."
  mkdir -p "$mount_dir"
  check_status "mkdir" $?
fi

# Used to rsync files in the project directory to output
function rsync_file() {
  if [ -f "$1" ]; then rsync -pEtu $1 "$output/"
  elif [ -d "$1" ]; then rsync -pEtur $1 "$output/"
  fi
  check_status "rsync" $?
}

# Rsync files to output
echo "Synchronizing files to output.."
rsync_file $part_setup
rsync_file $slides_tar
if [ -d "$slides_dir" ] && [ $cp_slides = "1" ]; then rsync_file "$slides_dir"; fi
rsync_file *.png
if [ -d "$common" ]; then rsync_file "$common/"*.png; fi
rsync_file "$rele_notes"

# Stuff used to generate JSON
json_indent="\t"
json_grab=""
json=""

function json_append_fields() {
  local list="$json_fields"
  local found=0
  json_grab=""
  while [ -n "$list" ]; do
    local line=$(printf "$list" | head -n 1)
    list=$(printf "$list" | tail -n +2)
    if [ -n "$line" ]; then
      local key=$(printf "$line" | awk -F= '{print $1}' | sed "$sed_trim")
      local val=$(printf "$line" | awk -F= '{$1=""; print $0}' | sed "$sed_trim")
      local v5=${key::5}
      if [[ "$v5" = "$1:" || "$v5" = "both:" ]]; then
        key="${key:5}"
        json="$json$json_indent\"$key\": "$val",\n"
      elif [ "${key::3}" = "$1:" ]; then
        key="${key:3}"
        json="$json$json_indent\"$key\": "$val",\n"
      fi
      if [ "$key" = "$2" ]; then json_grab=$val; fi
    fi
  done
}

function json_append() {
  if [ -n "$2" ]; then
    if [ $3 -eq 1 ]; then
      json="$json$json_indent\"$1\": \"$2\",\n"
    else
      json="$json$json_indent\"$1\": $2,\n"
    fi
  fi
}

# Generate os.json
echo "Generating os.json.."
json="{\n"
json_append_fields "os" "name"
json_append "$checksum" "$(get_checksum "$output/partition_setup.sh")" 1
echo -e "${json::-3}\n}" > "$output/os.json"
icon=$(echo $json_grab | sed 's/^"//;s/"$//')

echo "Generating partitions.json.."

# Handle the wanted partitions
for part_id in ${parts[@]}; do
  
  # Get info for partition
  part_info=$(echo "$fdisk_out" | grep ^"$extract_name$part_id")
  
  # Get start and size (in sectors / blocks)
  part_first=$(echo "$part_info" | awk '{print $2}' | sed -En $sed_numval)
  part_count=$(echo "$part_info" | awk '{print $3}' | sed -En $sed_numval)
  part_bytes=$(echo "$part_info" | awk '{print $4}' | sed -En $sed_numval)
  
  # Validate the values
  if [ -z "$part_first" ] || [ -z "$part_count" ] || [ -z "$part_bytes" ]; then
    echo "fdisk returned non-parseable info: '$part_info'!"
    exit $E_BAD_FDISK
  fi
  
  # Calculate sector size as: byte size / sector count
  part_sector=$((part_bytes / part_count))
  
  debug_print "part_first='$part_first'"
  debug_print "part_count='$part_count'"
  debug_print "part_bytes='$part_bytes'"
  debug_print "part_sector='$part_sector'"
  
  echo "Handling partition '$part_id': sector size=$part_sector, first=$part_first, count=$part_count, bytes=$part_bytes"
  
  get_partcfg "$part_id"
  
  tarballs=$(string_replace "$tarballs" "@$part_id" "$p_name")
  
  mount_args=""
  mount_name=$extract_name
  if [ $blockdev -eq 1 ]; then
    mount_name=$mount_name$part_id
  else
    mount_args="-o loop,rw,offset=$((part_first * part_sector)),sizelimit=$part_bytes ";
  fi
    
  debug_print "mount $mount_args\"$mount_name\" \"$mount_dir\""
    
  # Mount the partition
  echo "Mounting partition.."
  mount $mount_args"$mount_name" "$mount_dir"
  check_status "mount" $?
  echo "Partition mounted.."
    
  # Change directory to the mount point
  cd "$mount_dir"
  check_status "cd" $?
    
  # Delete socket files?
  if [ $p_nosock -eq 1 ]; then
    echo "Deleting socket files.."
    find . -type s -exec rm {} \;
    check_status "find|rm" $?
  fi
    
  # Get acl?
  if [ $p_getfacl -eq 1 ]; then
    echo "Creating acl file if needed.."
    acl=$(getfacl -s -R .)
    check_status "getfacl" $?
    if [ -n "$acl" ]; then echo "$acl" > "acl_permissions.pinn"; fi
  fi
  
  # Get used space in MiB
  fsys_size=$(df -BM --output=used . | tail -n 1 | sed "$sed_trim")
  fsys_size=${fsys_size::-1}
  #fsys_size=$((fsys_size + 1))
  debug_print "fsys_size='$fsys_size'"
  
  # Make tarball, get and calculate the sizes
  tar_name=$output"/"$p_name".tar"
  if [ $use_tar -eq 1 ]; then
  
    echo "Creating tarball '$tar_name'.."
    if [ $use_debug -eq 1 ]; then
      echo -ne "\033[0;34m"
      bsdtar --numeric-owner --format gnutar -cpvf "$tar_name" .
      echo -ne "\033[0m"
    else
      bsdtar --numeric-owner --format gnutar -cpvf "$tar_name" . 2> /dev/null
    fi
    check_status "bsdtar" $?
    tar_size=$(stat --printf="%s" "$tar_name")
    check_status "stat" $?
    
  else
  
    echo "Not creating tarball.."
    tar_size=0
    
  fi
  
  tar_size_mb=$((tar_size / 1048576 + 1))
  
  if [ $p_abs -gt $fsys_size ]; then
    nom_size=$((p_abs + p_add))
  else
    nom_size=$((fsys_size + p_add))
  fi
  
  debug_print "tar_size='$tar_size'"
  debug_print "tar_size_mb='$tar_size_mb'"
  debug_print "nom_size='$nom_size'"
    
  # Unmount the partition..
  cd ..
  echo "Unmounting partition.."
  umount "$mount_dir"
  check_status "umount" $?
    
  xz_name=$tar_name".xz"
  if [[ ($use_xz -eq 1) && (-f "$tar_name") ]]; then
  
    # Compress tarball with xz and get the size
    echo "Compressing the tarball to '$xz_name'.."
    if [ -f "$xz_name" ]; then rm "$xz_name"; fi;
    xz -9 -e "$tar_name"
    check_status "xz" $?
    xz_size=$(stat --printf="%s" "$xz_name")
    check_status "stat" $?
    
    # Get checksum
    echo "Calculating checksum of compressed tar ball.."
    xz_hash=$(get_checksum "$xz_name")
    
  else
    
    echo "Not compressing tarball.."
    xz_size=1
    xz_hash="$checksum"
    
  fi
    
  debug_print "xz_size='$xz_size'"
  debug_print "checksum='$xz_hash'"
    
  # Perform partitions specific replacements
  partitions=$(string_replace "$partitions" "@part"$part_id"size" "$((part_bytes))")
  partitions=$(string_replace "$partitions" "@part"$part_id"nominal_size" "$((nom_size))")
  partitions=$(string_replace "$partitions" "@part"$part_id"tarball_size" "$((tar_size_mb))")
  partitions=$(string_replace "$partitions" "@part"$part_id"checksum" "$xz_hash")
    
  # Add values
  download_size=$((download_size + xz_size))
  nominal_size=$((nominal_size + nom_size))
    
  echo "Partition '$part_id' successfully processed.."
    
done

# Save partitions.json
echo -e "$partitions" > "$output/partitions.json"

echo "Removing mount point.."
rmdir "$mount_dir"

# Generate os_list.json
echo "Generating os_list.json.."
json="$json_indent{\n"
json_end="\n$json_indent}"
json_indent="$json_indent$json_indent"

json_append_fields "list" "icon"


tballs="[\n"
for tb in ${tarballs[@]}; do
  if [ -n "$tb" ]; then tballs="$tballs$json_indent\t\"$base_url$tb.tar.xz\",\n"; fi
done
tballs="${tballs::-3}\n$json_indent]"


json_append "nominal_size" "$((nominal_size + addsize))" 0
json_append "download_size" "$download_size" 0
if [ -z "$json_grab" ] && [ -n "$icon" ]; then
  icon=$(echo -n "$icon" | sed 's/ /_/g')
  json_append "icon" "$base_url$icon"".png" 1
fi
json_append "marketing_info" "$base_url""marketing.jar" 1
json_append "os_info" "$base_url""os.json" 1
json_append "partition_setup" "$base_url""partition_setup.sh" 1
json_append "partitions_info" "$base_url""partitions.json" 1
json_append "tarballs" "$tballs" 0

echo -e "${json::-3}$json_end" > "$output/os_list.json"

# Set owner for the created files
echo "Changing ownership to $SUDO_USER.."
do_chown "$output"

# Store last release date
echo "Storing last succeeded release date.."
printf "$release_date" > "$check_file"
do_chown "$check_file"

# Cleanup?
if [ $use_cleanup -eq 1 ]; then
  echo "Cleaning up.."
  if [ -f "$archive" ]; then rm "$archive"; fi
  if [ -f "$extract_name" ]; then rm "$extract_name"; fi
fi

# No, not "ALL", Bundy..
echo "THAT'S AL FOLKS!"
