#!/bin/sh
#
# https://github.com/alexlafroscia/yaml-merge
# sudo npm install -g @alexlafroscia/yaml-merge
#

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
FORCE_LIST="environment_variable,volume,port,change,link,section,release,overview,device,unsupported_volume,extra_param"

usage() {
    echo "usage: $(basename $0) [OPTIONS...] WORKPATH

Generate files related to one or multiple Docker containers.

Arguments:
  WORKPATH         Working path.  See notes below.

Options:
  -b               Keep backup of modified file(s).
  -r               Only generate README.md.
  -d               Only generate DOCKERHUB.md.
  -u               Only generate unRAID template.
  -g               Only generate GitHub issue templates.
  -l               Only generate LICENSE.

The data source for templates are stored in:
  - appdefs.yml for Docker containers running an application.
  - baseimagedefs.yml for Docker baseimages.

WORKPATH can be:
  1) The path to the template data source file.
  2) The directory in which a template data source file can be found.
  3) The directory containing the 'docker-*/' folders in which template data
     source files can be found.
"
}

DO_BACKUP=false
DEBUG=0
WORKDIR="$(mktemp -d)"

clean_exit() {
    if [ "$DEBUG" -eq 0 ]; then
        rm -rf "$WORKDIR"
    else
        echo "Workdir: $WORKDIR"
    fi
}
trap "clean_exit" EXIT

die() {
    if [ -n "$*" ]; then
        echo "ERROR: $*"
    fi
    exit 1
}

copy_or_download() {
    SRC="$1"
    URL="$2"
    DST="$3"
    if [ -f "$SRC" ]; then
        cp "$SRC" "$DST"
    else
        curl -L -o "$DST" "$URL"
    fi
}

get_app_data_sources() {
    DATA_SOURCE="$1"

    # Add data source from GUI baseimage.
    if grep -q "gui_type: x11" "$DATA_SOURCE"; then
        copy_or_download \
            "$SCRIPT_DIR/../docker-baseimage-gui/baseimagedefs.yml" \
            "https://raw.githubusercontent.com/jlesage/docker-baseimage-gui/master/baseimagedefs.yml" \
            "$WORKDIR"/data-base-gui.yml
        "$YAML_MERGE" "$WORKDIR"/data-base-gui.yml "$DATA_SOURCE" > "$WORKDIR"/data.yml
        #merge-yaml -i "$WORKDIR"/data-base-gui.yml "$DATA_SOURCE" -o "$WORKDIR"/data.yml > /dev/null
    else
        cp "$DATA_SOURCE" "$WORKDIR"/data.yml
    fi

    # Add data source from baseimage.
    copy_or_download \
        "$SCRIPT_DIR/../docker-baseimage-multiarch/baseimagedefs.yml" \
        "https://raw.githubusercontent.com/jlesage/docker-baseimage/master/baseimagedefs.yml" \
        "$WORKDIR"/data-base.yml
    "$YAML_MERGE" "$WORKDIR"/data-base.yml "$WORKDIR"/data.yml > "$WORKDIR"/data-final.yml
    #merge-yaml -i "$WORKDIR"/data-base.yml "$WORKDIR"/data.yml -o "$WORKDIR"/data-final.yml

    echo "$WORKDIR"/data-final.yml
}

get_baseimage_data_sources() {
    DATA_SOURCE="$1"

    if grep -q "gui: true" "$DATA_SOURCE"; then
        copy_or_download \
            "$SCRIPT_DIR/../docker-baseimage-multiarch/baseimagedefs.yml" \
            "https://raw.githubusercontent.com/jlesage/docker-baseimage/master/baseimagedefs.yml" \
            "$WORKDIR"/data-base.yml
        "$YAML_MERGE" "$WORKDIR"/data-base.yml "$DATA_SOURCE" > "$WORKDIR"/data.yml
        #merge-yaml -i "$WORKDIR"/data-base.yml "$DATA_SOURCE" -o "$WORKDIR"/data.yml > /dev/null
    else
        cp "$DATA_SOURCE" "$WORKDIR"/data.yml
    fi

    echo "$WORKDIR"/data.yml
}

generate() {
    TEMPLATE="$1"
    DATA="$2"
    OUTPUT="$3"

    OUTPUT_BACKUP="$OUTPUT-$(date +%Y-%m-%d-%H-%M-%S)"

    if $DO_BACKUP; then
        if [ -f "$OUTPUT" ]; then
            cp "$OUTPUT" "$OUTPUT_BACKUP"
        fi
    fi

    echo "Generating $OUTPUT..."
    j2 --customize "$SCRIPT_DIR"/j2-customize.py "$TEMPLATE" "$DATA" > "$WORKDIR"/output.1
    j2 --customize "$SCRIPT_DIR"/j2-customize.py "$WORKDIR"/output.1 "$DATA" > "$WORKDIR"/output.2
    cp "$WORKDIR"/output.2 "$OUTPUT"

#    j2 --customize "$SCRIPT_DIR"/j2-customize.py "$TEMPLATE" "$DATA" > "$OUTPUT"

    # Remove the backup if generated file is the same.
    if $DO_BACKUP; then
        if [ -f "$OUTPUT_BACKUP" ]; then
            if diff "$OUTPUT" "$OUTPUT_BACKUP" > /dev/null; then
                rm "$OUTPUT_BACKUP"
            fi
        fi
    fi
}

generate_app_readme() {
    DEF_FILE="$(realpath "$1" 2> /dev/null)"
    DATA_SOURCE="$(get_app_data_sources "$(realpath "$1" 2> /dev/null)")"
    OUTPUT="$(dirname "$DEF_FILE")/README.md"

    [ -f "$SCRIPT_DIR/templates/app/README.md.j2" ] || die "README.md template: File not found: $SCRIPT_DIR/templates/app/README.md.j2"

    generate "$SCRIPT_DIR"/templates/app/README.md.j2 "$DATA_SOURCE" "$OUTPUT"

    # Add the TOC.
    "$SCRIPT_DIR"/gh-md-toc --no-backup --hide-footer --skip-header "$OUTPUT" > /dev/null
    sed -i "/<!--t[se]-->/d" "$OUTPUT"
}

generate_app_dockerhub_readme() {
    DEF_FILE="$(realpath "$1" 2> /dev/null)"
    DATA_SOURCE="$(get_app_data_sources "$(realpath "$1" 2> /dev/null)")"
    OUTPUT="$(dirname "$DEF_FILE")/DOCKERHUB.md"

    [ -f "$SCRIPT_DIR/templates/app/DOCKERHUB.md.j2" ] || die "DOCKERHUB.md template: File not found: $SCRIPT_DIR/templates/app/DOCKERHUB.md.j2"

    generate "$SCRIPT_DIR"/templates/app/DOCKERHUB.md.j2 "$DATA_SOURCE" "$OUTPUT"
}

generate_app_unraid_template() {
    DEF_FILE="$(realpath "$1" 2> /dev/null)"
    DATA_SOURCE="$(get_app_data_sources "$(realpath "$1" 2> /dev/null)")"
    APP_NAME="$(basename "$(dirname "$DEF_FILE")" | sed 's/docker-//')"
    UNRAID_TEMPLATE_DIR="$(realpath "$(dirname "$DEF_FILE")/../")"/docker-templates/jlesage
    OUTPUT="$UNRAID_TEMPLATE_DIR/$APP_NAME.xml"

    [ -f "$SCRIPT_DIR/templates/app/unraid_template.xml.j2" ] || die "unRAID template: File not found: $SCRIPT_DIR/templates/app/unraid_template.xml.j2"
    [ -d "$UNRAID_TEMPLATE_DIR" ] || die "unRAID template: Directory not found: $UNRAID_TEMPLATE_DIR"

    generate "$SCRIPT_DIR"/templates/app/unraid_template.xml.j2 "$DATA_SOURCE" "$OUTPUT"
}

generate_app_github_issue_templates() {
    DEF_FILE="$(realpath "$1" 2> /dev/null)"
    DATA_SOURCE="$(get_app_data_sources "$(realpath "$1" 2> /dev/null)")"

    [ -f "$SCRIPT_DIR/templates/app/github_issue_config.yml.j2" ] || die "GitHub issue templates: File not found: $SCRIPT_DIR/templates/app/github_issue_config.yml.j2"
    [ -f "$SCRIPT_DIR/templates/app/github_issue_bug_report.yml.j2" ] || die "GitHub issue templates: File not found: $SCRIPT_DIR/templates/app/github_issue_bug_report.yml.j2"
    [ -f "$SCRIPT_DIR/templates/app/github_issue_feature_request.yml.j2" ] || die "GitHub issue templates: File not found: $SCRIPT_DIR/templates/app/github_issue_feature_request.yml.j2"
    [ -f "$SCRIPT_DIR/templates/app/FUNDING.yml.j2" ] || die "GitHub issue templates: File not found: $SCRIPT_DIR/templates/app/FUNDING.yml.j2"

    mkdir -p "$(dirname "$DEF_FILE")/.github/ISSUE_TEMPLATE"

    OUTPUT="$(dirname "$DEF_FILE")/.github/ISSUE_TEMPLATE/config.yml"
    generate "$SCRIPT_DIR"/templates/app/github_issue_config.yml.j2 "$DATA_SOURCE" "$OUTPUT"

    OUTPUT="$(dirname "$DEF_FILE")/.github/ISSUE_TEMPLATE/bug-report.yml"
    generate "$SCRIPT_DIR"/templates/app/github_issue_bug_report.yml.j2 "$DATA_SOURCE" "$OUTPUT"

    OUTPUT="$(dirname "$DEF_FILE")/.github/ISSUE_TEMPLATE/feature-request.yml"
    generate "$SCRIPT_DIR"/templates/app/github_issue_feature_request.yml.j2 "$DATA_SOURCE" "$OUTPUT"

    OUTPUT="$(dirname "$DEF_FILE")/.github/FUNDING.yml"
    generate "$SCRIPT_DIR"/templates/app/FUNDING.yml.j2 "$DATA_SOURCE" "$OUTPUT"
}

generate_app_license() {
    DEF_FILE="$(realpath "$1" 2> /dev/null)"
    DATA_SOURCE="$(get_app_data_sources "$(realpath "$1" 2> /dev/null)")"

    [ -f "$SCRIPT_DIR/templates/app/LICENSE.j2" ] || die "LICENSE template: File not found: $SCRIPT_DIR/templates/app/LICENSE.j2"

    OUTPUT="$(dirname "$DEF_FILE")/LICENSE"
    generate "$SCRIPT_DIR"/templates/app/LICENSE.j2 "$DATA_SOURCE" "$OUTPUT"
}

generate_app_all() {
    case "$2" in
        all)
            generate_app_readme "$1"
            generate_app_dockerhub_readme "$1"
            generate_app_unraid_template "$1"
            generate_app_github_issue_templates "$1"
            generate_app_license "$1"
            ;;
        readme)
            generate_app_readme "$1"
            ;;
        dockerhub_readme)
            generate_app_dockerhub_readme "$1"
            ;;
        unraid_template)
            generate_app_unraid_template "$1"
            ;;
        github_issue_templates)
            generate_app_github_issue_templates "$1"
            ;;
        license)
            generate_app_license "$1"
            ;;
    esac
}

generate_baseimage_readme() {
    DEF_FILE="$(realpath "$1" 2> /dev/null)"
    DATA_SOURCE="$(get_baseimage_data_sources "$DEF_FILE")"
    OUTPUT="$(dirname "$DEF_FILE")/README.md"

    [ -f "$SCRIPT_DIR/templates/baseimage/README.md.j2" ] || die "README.md template: File not found: $SCRIPT_DIR/templates/baseimage/README.md.j2"

    generate "$SCRIPT_DIR"/templates/baseimage/README.md.j2 "$DATA_SOURCE" "$OUTPUT"

    # Add the TOC.
    "$SCRIPT_DIR"/gh-md-toc --no-backup --hide-footer --skip-header "$OUTPUT" > /dev/null
    sed -i "/<!--t[se]-->/d" "$OUTPUT"
}

generate_baseimage_dockerhub_readme() {
    DEF_FILE="$(realpath "$1" 2> /dev/null)"
    DATA_SOURCE="$(get_baseimage_data_sources "$DEF_FILE")"
    OUTPUT="$(dirname "$DEF_FILE")/DOCKERHUB.md"

    [ -f "$SCRIPT_DIR/templates/baseimage/DOCKERHUB.md.j2" ] || die "DOCKERHUB.md template: File not found: $SCRIPT_DIR/templates/baseimage/DOCKERHUB.md.j2"

    generate "$SCRIPT_DIR"/templates/baseimage/DOCKERHUB.md.j2 "$DATA_SOURCE" "$OUTPUT"
}

generate_baseimage_all() {
    case "$2" in
        all)
            generate_baseimage_readme "$1"
            generate_baseimage_dockerhub_readme "$1"
            ;;
        readme)
            generate_baseimage_readme "$1"
            ;;
        dockerhub_readme)
            generate_baseimage_dockerhub_readme "$1"
            ;;
        unraid_template)
            ;;
        github_issue_templates)
            ;;
        license)
            ;;
        *)
            die "Unexpected argument '$2'."
            ;;
    esac
}

# Make sure an argument is provided.
if [ -z "${1:-}" ]; then
    usage
    exit 1
fi

# Make sure required files are found.
#[ -f "$SCRIPT_DIR/templates/baseimage/README.md.j2" ] || die "README.md template: File not found: $SCRIPT_DIR/templates/baseimage/README.md.j2"
#[ -f "$SCRIPT_DIR/templates/app/README.md.j2" ] || die "README.md template: File not found: $SCRIPT_DIR/templates/app/README.md.j2"
#[ -f "$SCRIPT_DIR/templates/app/unraid_template.yml.j2" ] || die "unRAID template: File not found: $SCRIPT_DIR/templates/app/unraid_template.yml.j2"

WORKPATH=
ASSET_TO_GENERATE=all

# Parse arguments.
while [ "$#" -ne 0 ]
do
    case "$1" in
        --debug) DEBUG=1 ;;
        -b) DO_BACKUP=true ;;
        -r) ASSET_TO_GENERATE=readme ;;
        -d) ASSET_TO_GENERATE=dockerhub_readme ;;
        -u) ASSET_TO_GENERATE=unraid_template ;;
        -g) ASSET_TO_GENERATE=github_issue_templates ;;
        -l) ASSET_TO_GENERATE=license ;;
        -h)
            usage
            exit 1
            ;;
        -*)
            die "Unkown option: $1"
            ;;
        *)
            if [ -z "$WORKPATH" ]; then
                WORKPATH="$1"
            else
                die "Unexpected argument: $1"
            fi
            ;;
    esac
    shift
done

if [ -z "$WORKPATH" ]; then
    die "Workpath not set."
fi

YAML_MERGE="$SCRIPT_DIR"/yaml-merge/yaml-merge
[ -e "$YAML_MERGE" ] || die "yaml-merge not found"
[ -n "$(which j2)" ] || die "j2 not found"

# Handle the provided WORKPATH.
if [ -f "$WORKPATH" ]; then
    if [ "$(basename "$WORKPATH")" = "appdefs.yml" ]; then
        generate_app_all "$WORKPATH" "$ASSET_TO_GENERATE"
    elif [ "$(basename "$WORKPATH")" = "baseimagedefs.yml" ]; then
        generate_baseimage_all "$WORKPATH" "$ASSET_TO_GENERATE"
    else
        echo "Unexpected file name: $WORKPATH"
        exit 1
    fi
elif [ -d "$WORKPATH" ]; then
    if [ -f "$WORKPATH/appdefs.yml" ]; then
        generate_app_all "$WORKPATH/appdefs.yml" "$ASSET_TO_GENERATE"
    elif [ -f "$WORKPATH/baseimagedefs.yml" ]; then
        generate_baseimage_all "$WORKPATH/baseimagedefs.yml" "$ASSET_TO_GENERATE"
    else
        DATA_SOURCE_FILE_FOUND="$(mktemp)"
        echo 0 > "$DATA_SOURCE_FILE_FOUND"
        ls "$WORKPATH"/docker-*/baseimagedefs.yml 2>/dev/null | while read -r FILE; do
            generate_baseimage_all "$FILE" "$ASSET_TO_GENERATE"
            echo 1 > "$DATA_SOURCE_FILE_FOUND"
        done
        ls "$WORKPATH"/docker-*/appdefs.yml 2>/dev/null | while read -r FILE; do
            generate_app_all "$FILE" "$ASSET_TO_GENERATE"
            echo 1 > "$DATA_SOURCE_FILE_FOUND"
        done
        FOUND="$(cat "$DATA_SOURCE_FILE_FOUND")"
        rm "$DATA_SOURCE_FILE_FOUND"
        if [ "$FOUND" -eq 0 ]; then
            die "No appdefs.yml/baseimagedefs.yml file found."
        fi
    fi
else
    die "File or directory not found: $WORKPATH."
fi

echo "Done!"

# vim:ft=sh:ts=4:sw=4:et:sts=4
