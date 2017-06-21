#!/bin/sh

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
FORCE_LIST="environment_variable,volume,port,change,link,section,release,overview,device"

usage() {
    echo "usage: $(basename $0) WORKPATH

Generate the README.md and unRAID template of one or multiple Docker container
for GUI applications.

WORKPATH can be:
  1) The path to the 'appdefs.xml' template data source file.
  2) The directory in which 'appdefs.xml' template data source file can be found.
  3) The directory in which 'docker-*/appdefs.xml' template data source file(s)
    can be found.

Expected directory structure:
  root/ (3)
  ├── $(basename "$SCRIPT_DIR")/
  │   ├── templates/
  │   │   ├── README.md.j2             <--  Jinja2 template for documentation.
  │   │   └── unraid_templates.xml.j2  <--  Jinja2 template for unRAID template.
  │   ├── render_templates.sh          <--  This script.
  │   └── commonappdefs.xml            <--  Common template data source.
  ├── docker-templates/                <--  unRAID templates directory.
  │   └── jlesage/
  │       ├── app1.xml                 <--+ Generated unRAID template.
  │       ├── app2.xml
  │       ├── ...
  │       └── appX.xml
  ├── docker-app1/ (2)                 <--  App's docker container directory.
  │   ├── appdefs.xml (1)              <--  App specific template data source.
  │   └── README.md                    <--+ Generated documentation.
  ├── docker-app2/
  │   ├── appdefs.xml
  │   └── README.md
  ├── ...
  └── docker-appX/
      ├── appdefs.xml
      └── README.md
"
}

die() {
    if [ -n "$*" ]; then
        echo "ERROR: $*"
    fi
    exit 1
}

generate_readme() {
    APP_SOURCE_DATA="$(realpath "$1" 2> /dev/null)"
    README="$(dirname "$APP_SOURCE_DATA")/README.md"

    if [ -f "$README" ]; then
        cp "$README" "$README-$(date +%Y-%m-%d-%H-%M-%S)"
    fi

    echo "Generating $README..."
    curl -s https://raw.githubusercontent.com/jlesage/docker-render-template/master/render_template.sh | sh -s \
        "$SCRIPT_DIR/templates/README.md.j2" \
        "$SCRIPT_DIR/commonappdefs.xml" \
        "$APP_SOURCE_DATA" \
        --force-list "$FORCE_LIST" \
        > "$README"
}

generate_unraid_template() {
    APP_SOURCE_DATA="$(realpath "$1" 2> /dev/null)"
    APP_NAME="$(echo "$(basename "$(dirname "$APP_SOURCE_DATA")" | sed 's/docker-//')")"
    UNRAID_TEMPLATE_DIR="$(dirname "$APP_SOURCE_DATA")/../docker-templates/jlesage"
    UNRAID_TEMPLATE_DIR="$(realpath "$UNRAID_TEMPLATE_DIR")"
    UNRAID_TEMPLATE="$UNRAID_TEMPLATE_DIR/$APP_NAME.xml"

    if [ ! -d "$UNRAID_TEMPLATE_DIR" ]; then
        echo "Skipping generation of $APP_NAME unRAID template: Directory not found: $UNRAID_TEMPLATE_DIR."
        return
    fi

    if [ -f "$UNRAID_TEMPLATE" ]; then
        cp "$UNRAID_TEMPLATE" "$UNRAID_TEMPLATE-$(date +%Y-%m-%d-%H-%M-%S)"
    fi

    echo "Generating $UNRAID_TEMPLATE..."
    curl -s https://raw.githubusercontent.com/jlesage/docker-render-template/master/render_template.sh | sh -s \
        "$SCRIPT_DIR/templates/unraid_template.xml.j2" \
        "$SCRIPT_DIR/commonappdefs.xml" \
        "$APP_SOURCE_DATA" \
        --force-list "$FORCE_LIST" \
        > "$UNRAID_TEMPLATE"
}

generate_all() {
    generate_readme "$1"
    generate_unraid_template "$1"
}

# Make sure an argument is provided.
if [ "${1:-UNSET}" = "UNSET" ]; then
    usage
    exit 1
fi

# Make sure required files are found.
[ -f "$SCRIPT_DIR/commonappdefs.xml" ] || die "Common application data source: File not found: $SCRIPT_DIR/commonappdefs.xml"
[ -f "$SCRIPT_DIR/templates/README.md.j2" ] || die "README.md template: File not found: $SCRIPT_DIR/templates/README.md.j2"
[ -f "$SCRIPT_DIR/templates/unraid_template.xml.j2" ] || die "unRAID template: File not found: $SCRIPT_DIR/templates/unraid_template.xml.j2"

# Handle the provided WORKPATH.
WORKPATH="$1"
if [ -f "$WORKPATH" ]; then
    generate_all "$WORKPATH"
elif [ -d "$WORKPATH" ]; then
    if [ -f "$WORKPATH/appdefs.xml" ]; then
        generate_all "$WORKPATH/appdefs.xml"
    else
        DATA_SOURCE_FILE_FOUND="$(mktemp)"
        echo 0 > "$DATA_SOURCE_FILE_FOUND"
        ls "$WORKPATH"/docker-*/appdefs.xml 2>/dev/null | while read -r FILE; do
            generate_all "$FILE"
            echo 1 > "$DATA_SOURCE_FILE_FOUND"
        done
        FOUND="$(cat "$DATA_SOURCE_FILE_FOUND")"
        rm "$DATA_SOURCE_FILE_FOUND"
        if [ "$FOUND" -eq 0 ]; then
            die "No appdefs.xml file found."
        fi
    fi
else
    die "File or directory not found: $WORKPATH."
fi

echo "Done!"
