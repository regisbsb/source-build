#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
    echo "usage: $0 <path-to-tarball-root> [--skip-build] [--enable-leak-detection]"
    echo ""
}

if [ -z "${1:-}" ]; then
    usage
    exit 1
fi

TARBALL_ROOT=$1
shift

SKIP_BUILD=0
INCLUDE_LEAK_DETECTION=0
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

while :; do
    if [ $# -le 0 ]; then
        break
    fi

    lowerI="$(echo $1 | awk '{print tolower($0)}')"
    case $lowerI in
        -?|-h|--help)
            usage
            exit 0
            ;;
        --skip-build)
            SKIP_BUILD=1
            ;;
        --enable-leak-detection)
            INCLUDE_LEAK_DETECTION=1
            ;;
        *)
            echo "Unrecognized argument '$1'"
            usage
            exit 1
            ;;
    esac

    shift
done

export FULL_TARBALL_ROOT=$(readlink -f $TARBALL_ROOT)

if [ -e "$TARBALL_ROOT" ]; then
    echo "info: '$TARBALL_ROOT' already exists"
fi

export SCRIPT_ROOT="$(cd -P "$( dirname "$0" )" && pwd)"
SDK_VERSION=$(cat $SCRIPT_ROOT/DotnetCLIVersion.txt)

if [ $SKIP_BUILD -ne 1 ]; then

    if [ -e "$SCRIPT_ROOT/bin" ]; then
        rm -rf "$SCRIPT_ROOT/bin"
    fi

    $SCRIPT_ROOT/clean.sh
    $SCRIPT_ROOT/build.sh /p:ArchiveDownloadedPackages=true /flp:v=detailed
fi

mkdir -p "$TARBALL_ROOT"

echo 'Copying sources to tarball...'

# Use Git to put sources in the tarball. This ensure it's fresh, without having to clean and reset
# the working dir. This helps preserve diagnostic information if the tarball build doesn't work.

# Checkout non-submodule sources into tarball.
git --work-tree="$TARBALL_ROOT" checkout HEAD -- src
# Checkout submodule sources into tarball.
git submodule foreach --quiet --recursive '
    SCRIPT_SUBMODULE_PATH="$toplevel/$path"
    TARBALL_SUBMODULE_PATH="$FULL_TARBALL_ROOT/${SCRIPT_SUBMODULE_PATH#$SCRIPT_ROOT/}"
    mkdir -p "$TARBALL_SUBMODULE_PATH"
    echo "Checking out $(pwd) => $TARBALL_SUBMODULE_PATH ..."
    if [ "$(ls -A)" = ".git" ]; then
        # Checkout fails for an empty tree. (E.g. nuget-client submodule NuGet.Build.Localization.)
        echo "  Nothing to check out from $TARBALL_SUBMODULE_PATH"
    else
        git --work-tree="$TARBALL_SUBMODULE_PATH" checkout -- .
    fi'

echo 'Copying scripts and tools to tarball...'

cp $SCRIPT_ROOT/*.proj $TARBALL_ROOT/
cp $SCRIPT_ROOT/*.props $TARBALL_ROOT/
cp $SCRIPT_ROOT/*.targets $TARBALL_ROOT/
cp $SCRIPT_ROOT/init-tools.msbuild $TARBALL_ROOT/
cp $SCRIPT_ROOT/DotnetCLIVersion.txt $TARBALL_ROOT/
cp $SCRIPT_ROOT/ProdConFeed.txt $TARBALL_ROOT/
cp $SCRIPT_ROOT/smoke-test* $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/keys $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/patches $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/scripts $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/repos $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/tools-local $TARBALL_ROOT/
cp -r $SCRIPT_ROOT/bin/git-info $TARBALL_ROOT/

cp -r $SCRIPT_ROOT/Tools $TARBALL_ROOT/
rm -f $TARBALL_ROOT/Tools/dotnetcli/dotnet.tar
rm -f $TARBALL_ROOT/Tools/dotnetcli/sdk/$SDK_VERSION/nuGetPackagesArchive.lzma
rm -rf $TARBALL_ROOT/Tools/dotnetcli/store
rm -rf $TARBALL_ROOT/Tools/dotnetcli/additionalDeps
# Remove props file generated by CoreFX that contains the RuntimeOS value of the current machine.
# It artificially limits the tarball to be buildable on only the OS that created it.
rm -rf $TARBALL_ROOT/Tools/configuration/configuration.props

cp $SCRIPT_ROOT/support/tarball/build.sh $TARBALL_ROOT/build.sh

mkdir -p $TARBALL_ROOT/prebuilt/nuget-packages
mkdir -p $TARBALL_ROOT/prebuilt/source-built
find $SCRIPT_ROOT/packages -name '*.nupkg' -exec cp {} $TARBALL_ROOT/prebuilt/nuget-packages/ \;
find $SCRIPT_ROOT/bin/obj/x64/Release/nuget-packages -name '*.nupkg' -exec cp {} $TARBALL_ROOT/prebuilt/nuget-packages/ \;

if [ -e $SCRIPT_ROOT/testing-smoke/smoke-test-packages ]; then
    cp -rf $SCRIPT_ROOT/testing-smoke/smoke-test-packages $TARBALL_ROOT/prebuilt
fi

echo 'Removing source-built packages from tarball prebuilts...'

for built_package in $(find $SCRIPT_ROOT/bin/obj/x64/Release/blob-feed/packages/ -name '*.nupkg' | tr '[:upper:]' '[:lower:]')
do
    if [ -e $TARBALL_ROOT/prebuilt/nuget-packages/$(basename $built_package) ]; then
        rm $TARBALL_ROOT/prebuilt/nuget-packages/$(basename $built_package)
    fi
    if [ -e $TARBALL_ROOT/prebuilt/smoke-test-packages/$(basename $built_package) ]; then
        rm $TARBALL_ROOT/prebuilt/smoke-test-packages/$(basename $built_package)
    fi
done

echo 'Copying source-built packages to tarball to replace packages needed before they are built...'

for built_package in $(find $SCRIPT_ROOT/bin/obj/x64/Release/blob-feed/packages/ -name '*.nupkg')
do
    cp $built_package $TARBALL_ROOT/prebuilt/source-built/
done

echo 'WORKAROUND: Overwriting the source-built roslyn-tools MSBuild files with prebuilt so that roslyn-tools can successfully build in the tarball... (https://github.com/dotnet/source-build/issues/654)'

ROSLYN_TOOLS_PACKAGE='RoslynTools.RepoToolset'
JSON_LINE=$(grep "$ROSLYN_TOOLS_PACKAGE" "$SCRIPT_ROOT/src/roslyn-tools/global.json")
# Remove spaces.
JSON_LINE=${JSON_LINE// }

# Isolate version from something like: "RoslynTools.RepoToolset":"1.0.0-beta2-62805-03"
PREFIX="\"$ROSLYN_TOOLS_PACKAGE\":\""
ROSLYN_TOOLS_REPO_TOOLSET_VERSION=${JSON_LINE:${#PREFIX}:$((${#JSON_LINE} - ${#PREFIX} - 1))}
REPO_TOOLSET_PACKAGE_DIR="$SCRIPT_ROOT/packages/${ROSLYN_TOOLS_PACKAGE,,}/$ROSLYN_TOOLS_REPO_TOOLSET_VERSION"

if [ ! -d "$REPO_TOOLSET_PACKAGE_DIR" ]; then
    echo "Failed to find repo toolset at: $REPO_TOOLSET_PACKAGE_DIR"
    exit 1
fi

SOURCE_BUILT_SDK_TOOLS_DIR="$TARBALL_ROOT/Tools/source-built/$ROSLYN_TOOLS_PACKAGE/tools"
cp "$REPO_TOOLSET_PACKAGE_DIR/tools/"*.props "$SOURCE_BUILT_SDK_TOOLS_DIR"
cp "$REPO_TOOLSET_PACKAGE_DIR/tools/"*.targets "$SOURCE_BUILT_SDK_TOOLS_DIR"

if [ $INCLUDE_LEAK_DETECTION -eq 1 ]; then
  echo 'Building leak detection MSBuild tasks...'
  ./Tools/dotnetcli/dotnet restore $SCRIPT_ROOT/tools-local/tasks/Microsoft.DotNet.SourceBuild.Tasks.LeakDetection/Microsoft.DotNet.SourceBuild.Tasks.LeakDetection.csproj --source $FULL_TARBALL_ROOT/prebuilt/source-built --source $FULL_TARBALL_ROOT/prebuilt/nuget-packages
  ./Tools/dotnetcli/dotnet publish -o $FULL_TARBALL_ROOT/tools-local/tasks/Microsoft.DotNet.SourceBuild.Tasks.LeakDetection $SCRIPT_ROOT/tools-local/tasks/Microsoft.DotNet.SourceBuild.Tasks.LeakDetection/Microsoft.DotNet.SourceBuild.Tasks.LeakDetection.csproj
fi

echo 'Recording commits for the source-build repo and all submodules, to aid in reproducibility...'

cat >$TARBALL_ROOT/source-build-info.txt << EOF
source-build:
 $(git rev-parse HEAD) . ($(git describe --always HEAD))

submodules:
$(git submodule status --recursive)
EOF

echo "Done. Tarball created: $TARBALL_ROOT"
