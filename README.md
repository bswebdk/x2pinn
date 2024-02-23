**WARNING** Do ***NOT*** download and execute any type of code or application unless
you are absolutely sure that it is safe to do so! **Really,** ***DON'T..!!!***

---

# X2PINN rev. 1 - BETA

The purpose of this **BASH** script is to automate the process of converting a Raspberry
Pi compatible system image for installation via **PINN**. It has been created and tested
using \*buntu 22.04 and it must be run with **sudo** in order to be able to do its magic.

The script loads an INI-style project file which contains settings used to perform the
conversion and then it performs the following workflow:

1. Download the compressed system image with **wget**, if required.
2. Extract the downloaded archive (supported are: gz, xz, lzma, zip, 7z).
3. Examine the extracted image with **fdisk** in order to get partition info and sector size.
4. Mount the wanted partition(s).
5. Perform selected tasks in the mounted file system(s).
6. Tarball the file system(s) with **bsdtar**.
7. Compress the tarball(s) with **xz**.
8. Generate JSON files required by **PINN**.

During the process, the script will recover informations such as checksums, partition size(s),
file system sizes(s) and so on which are used to generate the JSON files.

Partitions are mounted to a mount point (directory) named "mnt" in the project directory.
The mount point will be created and removed by the script with root as owner. If the mount
point already exists and has content, the script will exit.

The following command line arguments may be used with the script:

- **\-\-cleanup** Delete the downloaded archive and extracted system image after successful
  conversion.
- **\-\-debug** Print (blue) debugging info.
- **\-\-fdisk\-only** When creating a new project, it may be useful to have the output
  from **fdisk** for the system image. Using this argument will cause x2pinn to download,
  extract and examine the image with fdisk whereafter the info is echoed and the script exits.
- **\-\-no\-check** After a successful conversion, x2pinn stores the release date of the project
  to a file named **x2pinn.txt.rd**. Whenever the script is re-run for the project, it will
  exit if the projects release date matches the date stored to the **\*.rd** file, in order to
  prevent the same conversion from being performed twice. If you want to disable this check,
  use this argument.
- **\-\-no\-tar** For testing, this option will skip the creation of the tarball.
- **\-\-no\-xz** For testing, this will skip the compression of the tarball.

## Project structure

In the project directory, the following files are expected to be found: **x2pinn.txt** and
**partitions.json**. You may also put **partition_setup.sh** and **marketing.tar** (*) in the
project directory, in which case they will be rsync'ed to the output directory, or they may
be put in the output directory - but they must exist in either location. Optional files are
**release_notes.txt** and any **\*.png** file(s) which are all rsync'ed to the output
directory.

**(\*)**  If "marketing.tar" does not exist, but a directory named "slides_vga" does, then
x2pinn will use **bsdtar** to create "marketing.tar" from "slides_vga".

## The project file: x2pinn.txt

The project file is basically an INI-style list of key=value pairs and it must have a
line feed (empty line) at the end, or the last line may be ignored. Lines starting with "#"
and empty/blank lines are ignored. Keys and values are trimmed for blank spaces in the ends.
A blank space is used as separator for token lists (**tarballs**, **part[id]**).

The following keys are used:

- **archive** The local name used for the downloaded archive. If undefined, the archive
  name is extracted from **download** by taking what is after the last "/" and then
  what is before the first "?" (if any).
- **download** This is the URL from where to download the compressed system image with **wget**.
  If undefined, **archive** must point to an existing, local archive file. A previously
  interrupted download will be resumed, if possible.
- **output** The destination directory for the generated archive(s), JSON files and so on. This
  path may be relative to the project file. If undefinied, "os" is used. If the specified path
  does not exists, it will be created (mkdir -p).
- **addsize** An amount of extra space added to "nominal_size" in "os_list.json". This may
  be useful if the project contains empty partitions which are to be created by **PINN**.
- **part*****[id]*** Is a list of tokens each defining a setting to be used when processing the
  partition with the ident *[id]*. When examining a system image with "fdisk -l system_image.img",
  a list of partitions named "system_image.img1", "system_image.img2", "system_image.img3" and so
  on will be displayed and the idents are the numbers appended to the file name (here: 1, 2 and 3).  
  The first token ***MUST*** be the name of the partition which is used to create the output
  tarball/archive. After this, there may be added zero or more of the following tokens:  
  > **nosock** Delete all socket files in the file system.  
  > **getfacl** Generate a "acl_permissions.pinn" file in the file systems root directory,
    the file will not be stored if empty.  
  > **+*****[n]*** A value to add to the nominal size of the file system. A valid value
    could be **+512** which would add 512MiB to the actual size of the file system.
- **sector** The sector size used in the system images. If undefined, an attempt to extract
  it with **fdisk** from the system image itself will be attempted.
- **tarballs** A list of tokens defining the names of the partitions / tarballs which has to
  be added to "os_list.json". You may use **@*****[id]*** which will be substituted with the
  name of the partition with the specified ident. If **tarballs** is undefined, all the processed
  partition names is used instead.
- **base_url** The base url from where the output is to be downloaded. This is basically a prefix
  for all urls in os_list.json.
- **checksum** The type of checksum wanted (valid values: **sha512sum**, **sha256sum**, **sha1sum**
  and **md5sum**, default is **sha512sum**).
- ***file*****:*****field*****=*****value*** There may be multiple of these lines which are copied
  to the wanted JSON file(s). ***file*** may be either **os** for "os.json", **list** for "os_list.json"
  or **both** if the value goes to both "os.json" and "os_list.json". ***field*** may be any of the
  JSON fields listed in the **PINN** documentation and ***value*** is the value of the field. Anything
  goes and valid values could be a "quoted string", \[ "an", "array", "of", "values" \] or a simple
  number / boolean.  
  **TIP!** If "*list:icon*" is undeclared, x2pinn will create it from the values: *base_url* +
  *os:name* + *.png*.
  
You may also use x2pinn to convert an existing system from a bootable block device (SD-card, USB-drive
etc.). To do this, **download** must be undefined and **archive** must be set to the wanted device (eg.
"/dev/sdb" and ***NOT*** "/dev/sdb1") and make sure that all partitions in the selected device are
**un-mounted**. Please remember to **back up the original system** before processing it with x2pinn!

### partitions.json

The template version of the "partitions.json" file used by **PINN** may use the following
variables which are then substituted in the output:

- **@part[id]size** The actual size of the partition including empty space.
- **@part[id]nominal_size** The nominal size of the file system excluding empty space
  but including extra space defined for the partition.
- **@part[id]tarball_size** The size of the uncompressed tarball.
- **@part[id]checksum** The checksum of the compressed tarball.

All sizes are in MiB (bytes / 1048576) and *[id]* is a substitude for the
partition ident.

## Exit status

If an error occurs during the execution, x2pinn will exit without doing any
cleanup. Exit status of the script is either of the following:

> **0** Success.  
> **1** Not running as root.  
> **2** Unknown command line argument.  
> **3** Required file(s) are missing.  
> **4** External command returned non-zero exit status.  
> **5** Mount point not empty.  
> **6** Project contains invalid key(s).  
> **7** **archive** is unspecified.  
> **8** **release_date** has not changed since last success.  
> **9** **download** is unspecified.  
> **10** Unsupported archive type.  
> **11** **sector** is unspecified.  
> **12** Partition settings are unspecified or malformed.  

## Sources of information

- [PINN Readme](https://github.com/procount/pinn/blob/master/README_PINN.md)
- [PINN How to multiboot existing OS'es](https://github.com/procount/pinn/wiki/How-to-Create-a-Multi-Boot-SD-card-out-of-2-existing-OSes-using-PINN)
- [PINN JSON fields](https://github.com/procount/pinn/wiki/JSON-fields)
