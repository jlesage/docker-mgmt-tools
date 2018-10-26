#!/bin/sh

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
FORCE_LIST="environment_variable,volume,port,change,link,section,release,overview,device,unsupported_volume,extra_param"

usage() {
    echo "usage: $(basename $0) WORKPATH [-r|-u]

Generate the README.md and unRAID template of one or multiple Docker containers.

Arguments:
  WORKPATH         Working path.  See notes below.

Options:
  -r               Only generate the README.md.
  -u               Only generate unRAID template.

The data source for templates are stored in:
  - appdefs.xml for Docker containers running an application.
  - baseimagedefs.xml for Docker baseimages.

WORKPATH can be:
  1) The path to the template data source file.
  2) The directory in which a template data source file can be found.
  3) The directory containing the 'docker-*/' folders in which  template data
     source files can be found.
"
}

die() {
    if [ -n "$*" ]; then
        echo "ERROR: $*"
    fi
    exit 1
}

get_app_data_sources() {
    DATA_SOURCE="$1"
    DATA_SOURCES="'$DATA_SOURCE'"

    # Add data source from GUI baseimage.
    if cat "$DATA_SOURCE" | grep -iq '<gui_type>x11</gui_type>'; then
        if [ -f "$SCRIPT_DIR/../docker-baseimage-gui/baseimagedefs.xml" ]; then
            DATA_SOURCES="'$(realpath "$SCRIPT_DIR/../docker-baseimage-gui/baseimagedefs.xml")' $DATA_SOURCES"
        else
            DATA_SOURCES="'https://raw.githubusercontent.com/jlesage/docker-baseimage-gui/master/baseimagedefs.xml' $DATA_SOURCES"
        fi
    fi
    # Add data source from baseimage.
    if [ -f "$SCRIPT_DIR/../docker-baseimage/baseimagedefs.xml" ]; then
        DATA_SOURCES="'$(realpath "$SCRIPT_DIR/../docker-baseimage/baseimagedefs.xml")' $DATA_SOURCES"
    else
        DATA_SOURCES="'https://raw.githubusercontent.com/jlesage/docker-baseimage/master/baseimagedefs.xml' $DATA_SOURCES"
    fi

    echo "$DATA_SOURCES"
}

get_baseimage_data_sources() {
    DATA_SOURCE="$1"
    DATA_SOURCES="'$DATA_SOURCE'"

    if [ "$(basename "$(dirname "$DATA_SOURCE")")" = "docker-baseimage-gui" ]; then
        if [ -f "$SCRIPT_DIR/../docker-baseimage/baseimagedefs.xml" ]; then
            DATA_SOURCES="'$(realpath "$SCRIPT_DIR/../docker-baseimage/baseimagedefs.xml")' $DATA_SOURCES"
        else
            DATA_SOURCES="'https://raw.githubusercontent.com/jlesage/docker-baseimage/master/baseimagedefs.xml' $DATA_SOURCES"
        fi
    fi

    echo "$DATA_SOURCES"
}

generate() {
    TEMPLATE="$1"
    OUTPUT="$2"
    shift 2

    OUTPUT_BACKUP="$OUTPUT-$(date +%Y-%m-%d-%H-%M-%S)"

    if [ -f "$OUTPUT" ]; then
        cp "$OUTPUT" "$OUTPUT_BACKUP"
    fi

    echo "Generating $OUTPUT..."
    curl -s https://raw.githubusercontent.com/jlesage/docker-render-template/master/render_template.sh | sh -s \
        "$TEMPLATE" \
        "$@" \
        --force-list "$FORCE_LIST" \
        > "$OUTPUT"

    # Remove the backup if generated file is the same.
    if [ -f "$OUTPUT_BACKUP" ]; then
        if diff "$OUTPUT" "$OUTPUT_BACKUP" > /dev/null; then
            rm "$OUTPUT_BACKUP"
        fi
    fi
}

generate_app_readme() {
    DATA_SOURCE="$(realpath "$1" 2> /dev/null)"
    DATA_SOURCES="$(get_app_data_sources "$DATA_SOURCE")"
    README="$(dirname "$DATA_SOURCE")/README.md"

    eval "generate '$SCRIPT_DIR/templates/app/README.md.j2' '$README' $DATA_SOURCES"

    # Add the TOC.
    TOC="$(mktemp)"
    "$SCRIPT_DIR"/gh-md-toc "$README" > "$TOC"
    sed -i "/^TABLE_OF_CONTENT$/r $TOC" "$README"
    sed -i "/^TABLE_OF_CONTENT$/,+1d" "$README"
    rm "$TOC"
}

generate_app_unraid_template() {
    DATA_SOURCE="$(realpath "$1" 2> /dev/null)"
    DATA_SOURCES="$(get_app_data_sources "$DATA_SOURCE")"
    APP_NAME="$(echo "$(basename "$(dirname "$DATA_SOURCE")" | sed 's/docker-//')")"
    UNRAID_TEMPLATE_DIR="$(dirname "$DATA_SOURCE")/../docker-templates/jlesage"
    UNRAID_TEMPLATE_DIR="$(realpath "$UNRAID_TEMPLATE_DIR")"
    UNRAID_TEMPLATE="$UNRAID_TEMPLATE_DIR/$APP_NAME.xml"

    eval "generate '$SCRIPT_DIR/templates/app/unraid_template.xml.j2' '$UNRAID_TEMPLATE' $DATA_SOURCES"
}

generate_app_all() {
    OPT="${2:-UNSET}"
    case "$OPT" in
        -r) generate_app_readme "$1" ;;
        -u) generate_app_unraid_template "$1" ;;
        *)
            generate_app_readme "$1"
            generate_app_unraid_template "$1"
            ;;
    esac
}

generate_baseimage_readme() {
    DATA_SOURCE="$(realpath "$1" 2> /dev/null)"
    DATA_SOURCES="$(get_baseimage_data_sources "$DATA_SOURCE")"
    README="$(dirname "$DATA_SOURCE")/README.md"

    eval "generate '$SCRIPT_DIR/templates/baseimage/README.md.j2' '$README' $DATA_SOURCES"

    # Add the TOC.
    TOC="$(mktemp)"
    "$SCRIPT_DIR"/gh-md-toc "$README" > "$TOC"
    sed -i "/^TABLE_OF_CONTENT$/r $TOC" "$README"
    sed -i "/^TABLE_OF_CONTENT$/,+1d" "$README"
    rm "$TOC"
}

generate_baseimage_all() {
    OPT="${2:-UNSET}"
    case "$OPT" in
        -r) generate_baseimage_readme "$1" ;;
        -u) ;;
        *)
            generate_baseimage_readme "$1"
            ;;
    esac
}

# Make sure an argument is provided.
if [ "${1:-UNSET}" = "UNSET" ]; then
    usage
    exit 1
fi

# Make sure required files are found.
[ -f "$SCRIPT_DIR/templates/baseimage/README.md.j2" ] || die "README.md template: File not found: $SCRIPT_DIR/templates/baseimage/README.md.j2"
[ -f "$SCRIPT_DIR/templates/app/README.md.j2" ] || die "README.md template: File not found: $SCRIPT_DIR/templates/app/README.md.j2"
[ -f "$SCRIPT_DIR/templates/app/unraid_template.xml.j2" ] || die "unRAID template: File not found: $SCRIPT_DIR/templates/app/unraid_template.xml.j2"

# Handle the provided WORKPATH.
WORKPATH="$1"
shift
if [ -f "$WORKPATH" ]; then
    if [ "$(basename "$WORKPATH")" = "appdefs.xml" ]; then
        generate_app_all "$WORKPATH" "$@"
    elif [ "$(basename "$WORKPATH")" = "baseimagedefs.xml" ]; then
        generate_baseimage_all "$WORKPATH" "$@"
    else
        echo "Unexpected file name: $WORKPATH"
        exit 1
    fi
elif [ -d "$WORKPATH" ]; then
    if [ -f "$WORKPATH/appdefs.xml" ]; then
        generate_app_all "$WORKPATH/appdefs.xml" "$@"
    elif [ -f "$WORKPATH/baseimagedefs.xml" ]; then
        generate_baseimage_all "$WORKPATH/baseimagedefs.xml" "$@"
    else
        DATA_SOURCE_FILE_FOUND="$(mktemp)"
        echo 0 > "$DATA_SOURCE_FILE_FOUND"
        ls "$WORKPATH"/docker-*/baseimagedefs.xml 2>/dev/null | while read -r FILE; do
            generate_baseimage_all "$FILE" "$@"
            echo 1 > "$DATA_SOURCE_FILE_FOUND"
        done
        ls "$WORKPATH"/docker-*/appdefs.xml 2>/dev/null | while read -r FILE; do
            generate_app_all "$FILE" "$@"
            echo 1 > "$DATA_SOURCE_FILE_FOUND"
        done
        FOUND="$(cat "$DATA_SOURCE_FILE_FOUND")"
        rm "$DATA_SOURCE_FILE_FOUND"
        if [ "$FOUND" -eq 0 ]; then
            die "No appdefs.xml/baseimagedefs.xml file found."
        fi
    fi
else
    die "File or directory not found: $WORKPATH."
fi

echo "Done!"
