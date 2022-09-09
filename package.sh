#!/bin/bash

readonly ARG_PASSPHRASE="passphrase"
declare passphrase


while [ $# -gt 0 ]; do
    case "$1" in
	--"$ARG_PASSPHRASE")
	passphrase="$2"
	shift; shift;
	;;
	*)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
    esac
done
if [[ -z $passphrase ]]; then
    echo "You must declare the passphrase --$ARG_PASSPHRASE flag" >&2
    exit 1
  fi
initialdir=`pwd`;

echo "Build and package php-pdo_sqlsrv";

echo "operating in dir: `pwd`";

echo "Creating artifact directory";
mkdir -vp $initialdir/package-artifacts;

distrocodename=`cat /etc/lsb-release | grep DISTRIB_CODENAME | cut -d'=' -f2`;
if [ "$distrocodename" != "bionic" ] && [ "$distrocodename" != "jammy" ];
then
	echo "Only Ubuntu 18.04 (bionic) or 22.04 (jammy) is supported)"
	exit 1;
fi

if [ -f php-pdo-sqlsrv/version ]
then
	pdosqlsrvver=`cat php-pdo-sqlsrv/version`;
	if [ "$pdosqlsrvver" != "" ];
	then
		echo "Building php-pdo_sqlsrv version: $pdosqlsrvver";
	else
		echo "Unable to determine version";
		exit 1;
	fi
else
	echo "Unable to determine version";
	exit 1;
fi


echo "Installing dependencies";
apt-get update;
DEBIAN_FRONTEND=noninteractive ACCEPT_EULA=Y apt-get -y install msodbcsql17 mssql-tools unixodbc-dev;

echo "PECL Build";
pecl install "pdo_sqlsrv-$pdosqlsrvver";

phpver=$(php -v | head -n1 | awk '{print $2}' | cut -d'.' -f1-2);
echo "For php version: $phpver";

zendapi=$(php -i | grep 'PHP API' | awk {'print $4'});
echo "Zend API: $zendapi";

mkdir php$phpver-pdosqlsrv-$pdosqlsrvver;

cp -v "/usr/lib/php/$zendapi/pdo_sqlsrv.so"  "php$phpver-pdosqlsrv-$pdosqlsrvver"/;
cp -v "$initialdir"/php-pdo-sqlsrv-package/extra/* "php$phpver-pdosqlsrv-$pdosqlsrvver"/;

tar czvf "php$phpver-pdosqlsrv_$pdosqlsrvver.orig.tar.gz" "php$phpver-pdosqlsrv-$pdosqlsrvver";

cp -vfR "$initialdir/php-pdo-sqlsrv-package/debian" "php$phpver-pdosqlsrv-$pdosqlsrvver"/;

cd php$phpver-pdosqlsrv-$pdosqlsrvver;

mv -v debian/phpX.Y-pdosqlsrv.install debian/php$phpver-pdosqlsrv.install;
sed -i "s/X\.Y/$phpver/g" debian/*;
sed -i "s/YYYYMMDD/$zendapi/g" debian/*;
sed -i "s/DISTROCODENAME/$distrocodename/g" debian/*;
sed -i "s/PDO_SQLSRVVER/$pdosqlsrvver/g" debian/*;
# Build!
debuild -i -I -us -uc;
if [ $? -ne 0 ];
then
        echo "Build failed";
        exit 1;
fi

echo "Copy deb files to package-artifacts";
cp -vf ../*.deb $initialdir/package-artifacts;

echo "Artifact List: `readlink -f $initialdir/package-artifacts/`";
ls -lhR $initialdir/package-artifacts/;

echo "Creating package tarball";
cd $initialdir;
tar czvf php$phpver-pdo_sqlsrv-package.tar.gz package-artifacts;
if [ $? -ne 0 ];
then
        echo "Unable to tarball packages";
        exit 1;
fi

cp -v php$phpver-pdo_sqlsrv-package.tar.gz $initialdir/package-artifacts/;

./php-pdo-sqlsrv-package/publish.sh --passphrase "$passphrase" --package "$(realpath package-artifacts/*deb)" --local-repo "ubuntu-$distrocodename"
