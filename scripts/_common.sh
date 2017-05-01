#!/bin/bash

#=================================================
#=================================================
# TESTING
#=================================================
#=================================================

ynh_setup_source () {
	src_url=$(cat ../conf/app.src | grep SOURCE_URL | cut -d= -f2-)
	src_checksum=$(cat ../conf/app.src | grep SOURCE_SUM | cut -d= -f2-)
	arch_format=$(cat ../conf/app.src | grep ARCH_FORMAT | cut -d= -f2-)
	local_source="/opt/yunohost-apps-src/$YNH_APP_ID/source.$arch_format"

	if test -e "$local_source"
	then	# Use the local source file if it is present
		cp $local_source source.$arch_format
	else	# If not, download the source
		wget -nv -O source.$arch_format $src_url
    fi

	# Check the control sum
	echo "$src_checksum source.$arch_format" \
		| md5sum -c --status || ynh_die "Corrupt source"

	# Extract source into the app dir
	sudo mkdir -p "$final_path"
	if [ $(echo "$arch_format" | tr '[:upper:]' '[:lower:]') = "zip" ]
	then # Zip format
		# Using of a temp directory, because unzip doesn't manage --strip-components
		temp_dir=$(mktemp -d)
		unzip -quo source.zip -d "$temp_dir"
		sudo cp -a $temp_dir/*/. "$final_path"
		ynh_secure_remove "$temp_dir"
	elif [ $(echo "$arch_format" | tr '[:upper:]' '[:lower:]') = "tar.gz" ]; then
		sudo tar -x -f source.tar.gz -C "$final_path" --strip-components 1
	else
		ynh_die "Format d'archive non reconnu."
	fi

	# Apply patches
	if test -f ../sources/patches/*.patch; then
		(cd "$DEST" \
			&& for p in ${PKG_DIR}/patches/*.patch; do \
				sudo patch -p1 < $p; done) \
			|| ynh_die "Unable to apply patches"
	fi

	# Add supplementary files
	if test -e "../sources/extra_files"; then
		sudo cp -a ../sources/extra_files/. "$final_path"
	fi
}

ynh_nginx_config () {
	finalnginxconf="/etc/nginx/conf.d/$domain.d/$app.conf"
	ynh_compare_checksum_config "$finalnginxconf" 1
	sudo cp ../conf/nginx.conf "$finalnginxconf"

	# To avoid a break by set -u, use a void substitution ${var:-}. If the variable is not set, it's simply set with an empty variable.
	# Substitute in a nginx config file only if the variable is not empty
	if test -n "${path_url:-}"; then
		ynh_replace_string "__PATH__" "$path_url" "$finalnginxconf"
	fi
	if test -n "${domain:-}"; then
		ynh_replace_string "__DOMAIN__" "$domain" "$finalnginxconf"
	fi
	if test -n "${port:-}"; then
		ynh_replace_string "__PORT__" "$port" "$finalnginxconf"
	fi
	if test -n "${app:-}"; then
		ynh_replace_string "__NAME__" "$app" "$finalnginxconf"
	fi
	if test -n "${final_path:-}"; then
		ynh_replace_string "__FINALPATH__" "$final_path" "$finalnginxconf"
	fi
	ynh_store_checksum_config "$finalnginxconf"

	sudo systemctl reload nginx
}

ynh_remove_nginx_config () {
	ynh_secure_remove "/etc/nginx/conf.d/$domain.d/$app.conf"
	sudo systemctl reload nginx
}

ynh_store_checksum_config () {
	config_file_checksum=checksum_${1//[\/ ]/_}	# Replace all '/' and ' ' by '_'
	ynh_app_setting_set $app $config_file_checksum $(sudo md5sum "$1" | cut -d' ' -f1)
}

ynh_compare_checksum_config () {
	current_config_file=$1
	compress_backup=${2:-0}	# If $2 is empty, compress_backup will set at 0
	config_file_checksum=checksum_${current_config_file//[\/ ]/_}	# Replace all '/' and ' ' by '_'
	checksum_value=$(ynh_app_setting_get $app $config_file_checksum)
	if [ -n "$checksum_value" ]
	then	# Proceed only if a value was stocked into the app config
		if ! echo "$checksum_value $current_config_file" | sudo md5sum -c --status
		then	# If the checksum is now different
			backup_config_file="$current_config_file.backup.$(date '+%d.%m.%y_%Hh%M,%Ss')"
			if [ $compress_backup -eq 1 ]
			then
				sudo tar --create --gzip --file "$backup_config_file.tar.gz" "$current_config_file"	# Backup the current config file and compress
				backup_config_file="$backup_config_file.tar.gz"
			else
				sudo cp -a "$current_config_file" "$backup_config_file"	# Backup the current config file
			fi
			echo "Config file $current_config_file has been manually modified since the installation or last upgrade. So it has been duplicated in $backup_config_file" >&2
			echo "$backup_config_file"	# Return the name of the backup file
		fi
	fi
}

#=================================================
#=================================================

#=================================================
# CHECKING
#=================================================

CHECK_DOMAINPATH () {	# Vérifie la disponibilité du path et du domaine.
	sudo yunohost app checkurl $domain$path_url -a $app
}

#=================================================
# DISPLAYING
#=================================================

WARNING () {	# Écrit sur le canal d'erreur pour passer en warning.
	$@ >&2
}

QUIET () {	# Redirige la sortie standard dans /dev/null
	$@ > /dev/null
}

#=================================================
# BACKUP
#=================================================

BACKUP_FAIL_UPGRADE () {
	WARNING echo "Upgrade failed."
	app_bck=${app//_/-}	# Replace all '_' by '-'
	if sudo yunohost backup list | grep -q $app_bck-pre-upgrade$backup_number; then	# Vérifie l'existence de l'archive avant de supprimer l'application et de restaurer
		sudo yunohost app remove $app	# Supprime l'application avant de la restaurer.
		sudo yunohost backup restore --ignore-hooks $app_bck-pre-upgrade$backup_number --apps $app --force	# Restore the backup if upgrade failed
		ynh_die "The app was restored to the way it was before the failed upgrade."
	fi
}

BACKUP_BEFORE_UPGRADE () {	# Backup the current version of the app, restore it if the upgrade fails
	backup_number=1
	old_backup_number=2
	app_bck=${app//_/-}	# Replace all '_' by '-'
	if sudo yunohost backup list | grep -q $app_bck-pre-upgrade1; then	# Vérifie l'existence d'une archive déjà numéroté à 1.
		backup_number=2	# Et passe le numéro de l'archive à 2
		old_backup_number=1
	fi

	sudo yunohost backup create --ignore-hooks --apps $app --name $app_bck-pre-upgrade$backup_number	# Créer un backup différent de celui existant.
	if [ "$?" -eq 0 ]; then	# Si le backup est un succès, supprime l'archive précédente.
		if sudo yunohost backup list | grep -q $app_bck-pre-upgrade$old_backup_number; then	# Vérifie l'existence de l'ancienne archive avant de la supprimer, pour éviter une erreur.
			QUIET sudo yunohost backup delete $app_bck-pre-upgrade$old_backup_number
		fi
	else	# Si le backup a échoué
		ynh_die "Backup failed, the upgrade process was aborted."
	fi
}

HUMAN_SIZE () {	# Transforme une taille en Ko en une taille lisible pour un humain
	human=$(numfmt --to=iec --from-unit=1K $1)
	echo $human
}

CHECK_SIZE () {	# Vérifie avant chaque backup que l'espace est suffisant
	file_to_analyse=$1
	backup_size=$(sudo du --summarize "$file_to_analyse" | cut -f1)
	free_space=$(sudo df --output=avail "/home/yunohost.backup" | sed 1d)

	if [ $free_space -le $backup_size ]
	then
		WARNING echo "Espace insuffisant pour sauvegarder $file_to_analyse."
		WARNING echo "Espace disponible: $(HUMAN_SIZE $free_space)"
		ynh_die "Espace nécessaire: $(HUMAN_SIZE $backup_size)"
	fi
}

#=================================================
#=================================================
# FUTUR YNH HELPERS
#=================================================
# Importer ce fichier de fonction avant celui des helpers officiel
# Ainsi, les officiels prendront le pas sur ceux-ci le cas échéant
#=================================================

# Normalize the url path syntax
# Handle the slash at the beginning of path and its absence at ending
# Return a normalized url path
#
# example: url_path=$(ynh_normalize_url_path $url_path)
#          ynh_normalize_url_path example -> /example
#          ynh_normalize_url_path /example -> /example
#          ynh_normalize_url_path /example/ -> /example
#          ynh_normalize_url_path / -> /
#
# usage: ynh_normalize_url_path path_to_normalize
# | arg: url_path_to_normalize - URL path to normalize before using it
ynh_normalize_url_path () {
	path_url=$1
	test -n "$path_url" || ynh_die "ynh_normalize_url_path expect a URL path as first argument and received nothing."
	if [ "${path_url:0:1}" != "/" ]; then    # If the first character is not a /
		path_url="/$path_url"    # Add / at begin of path variable
	fi
	if [ "${path_url:${#path_url}-1}" == "/" ] && [ ${#path_url} -gt 1 ]; then    # If the last character is a / and that not the only character.
		path_url="${path_url:0:${#path_url}-1}"	# Delete the last character
	fi
	echo $path_url
}

# Manage a fail of the script
#
# Print a warning to inform that the script was failed
# Execute the ynh_clean_setup function if used in the app script
#
# usage of ynh_clean_setup function
# This function provide a way to clean some residual of installation that not managed by remove script.
# To use it, simply add in your script:
# ynh_clean_setup () {
#        instructions...
# }
# This function is optionnal.
#
# Usage: ynh_exit_properly is used only by the helper ynh_abort_if_errors.
# You must not use it directly.
ynh_exit_properly () {
	exit_code=$?
	if [ "$exit_code" -eq 0 ]; then
			exit 0	# Exit without error if the script ended correctly
	fi

	trap '' EXIT	# Ignore new exit signals
	set +eu	# Do not exit anymore if a command fail or if a variable is empty

	echo -e "!!\n  $app's script has encountered an error. Its execution was cancelled.\n!!" >&2

	if type -t ynh_clean_setup > /dev/null; then	# Check if the function exist in the app script.
		ynh_clean_setup	# Call the function to do specific cleaning for the app.
	fi

	ynh_die	# Exit with error status
}

# Exit if an error occurs during the execution of the script.
#
# Stop immediatly the execution if an error occured or if a empty variable is used.
# The execution of the script is derivate to ynh_exit_properly function before exit.
#
# Usage: ynh_abort_if_errors
ynh_abort_if_errors () {
	set -eu	# Exit if a command fail, and if a variable is used unset.
	trap ynh_exit_properly EXIT	# Capturing exit signals on shell script
}

# Define and install dependencies with a equivs control file
# This helper can/should only be called once per app
#
# usage: ynh_install_app_dependencies dep [dep [...]]
# | arg: dep - the package name to install in dependence
ynh_install_app_dependencies () {
    dependencies=$@
    manifest_path="../manifest.json"
    if [ ! -e "$manifest_path" ]; then
    	manifest_path="../settings/manifest.json"	# Into the restore script, the manifest is not at the same place
    fi
    version=$(sudo python3 -c "import sys, json;print(json.load(open(\"$manifest_path\"))['version'])")	# Retrieve the version number in the manifest file.
    dep_app=${app//_/-}	# Replace all '_' by '-'

    if ynh_package_is_installed "${dep_app}-ynh-deps"; then
		echo "A package named ${dep_app}-ynh-deps is already installed" >&2
    else
        cat > ./${dep_app}-ynh-deps.control << EOF	# Make a control file for equivs-build
Section: misc
Priority: optional
Package: ${dep_app}-ynh-deps
Version: ${version}
Depends: ${dependencies// /, }
Architecture: all
Description: Fake package for ${app} (YunoHost app) dependencies
 This meta-package is only responsible of installing its dependencies.
EOF
        ynh_package_install_from_equivs ./${dep_app}-ynh-deps.control \
            || ynh_die "Unable to install dependencies"	# Install the fake package and its dependencies
        ynh_app_setting_set $app apt_dependencies $dependencies
    fi
}

# Remove fake package and its dependencies
#
# Dependencies will removed only if no other package need them.
#
# usage: ynh_remove_app_dependencies
ynh_remove_app_dependencies () {
    dep_app=${app//_/-}	# Replace all '_' by '-'
    ynh_package_autoremove ${dep_app}-ynh-deps	# Remove the fake package and its dependencies if they not still used.
}

# Create a system user
#
# usage: ynh_system_user_create user_name [home_dir]
# | arg: user_name - Name of the system user that will be create
# | arg: home_dir - Path of the home dir for the user. Usually the final path of the app. If this argument is omitted, the user will be created without home
ynh_system_user_create () {
	if ! ynh_system_user_exists "$1"	# Check if the user exists on the system
	then	# If the user doesn't exist
		if [ $# -ge 2 ]; then	# If a home dir is mentioned
			user_home_dir="-d $2"
		else
			user_home_dir="--no-create-home"
		fi
		sudo useradd $user_home_dir --system --user-group $1 --shell /usr/sbin/nologin || ynh_die "Unable to create $1 system account"
	fi
}

# Delete a system user
#
# usage: ynh_system_user_delete user_name
# | arg: user_name - Name of the system user that will be create
ynh_system_user_delete () {
    if ynh_system_user_exists "$1"	# Check if the user exists on the system
    then
		echo "Remove the user $1" >&2
		sudo userdel $1
	else
		echo "The user $1 was not found" >&2
    fi
}

# Substitute/replace a string by another in a file
#
# usage: ynh_replace_string match_string replace_string target_file
# | arg: match_string - String to be searched and replaced in the file
# | arg: replace_string - String that will replace matches
# | arg: target_file - File in which the string will be replaced.
ynh_replace_string () {
	delimit=@
	match_string=${1//${delimit}/"\\${delimit}"}	# Escape the delimiter if it's in the string.
	replace_string=${2//${delimit}/"\\${delimit}"}
	workfile=$3

	sudo sed --in-place "s${delimit}${match_string}${delimit}${replace_string}${delimit}g" "$workfile"
}

# Remove a file or a directory securely
#
# usage: ynh_secure_remove path_to_remove
# | arg: path_to_remove - File or directory to remove
ynh_secure_remove () {
	path_to_remove=$1
	forbidden_path=" \
	/var/www \
	/home/yunohost.app"

	if [[ "$forbidden_path" =~ "$path_to_remove" \
		# Match all paths or subpaths in $forbidden_path
		|| "$path_to_remove" =~ ^/[[:alnum:]]+$ \
		# Match all first level paths from / (Like /var, /root, etc...)
		|| "${path_to_remove:${#path_to_remove}-1}" = "/" ]]
		# Match if the path finishes by /. Because it seems there is an empty variable
	then
		echo "Avoid deleting $path_to_remove." >&2
	else
		if [ -e "$path_to_remove" ]
		then
			sudo rm -R "$path_to_remove"
		else
			echo "$path_to_remove wasn't deleted because it doesn't exist." >&2
		fi
	fi
}
