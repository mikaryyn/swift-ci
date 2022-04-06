#!/bin/sh

# Base path of the SwiftCI script.
base_path=$( dirname $( readlink -f "${BASH_SOURCE:-$0}" ) )

# Path to compiled executable.
executable=$base_path/.build/release/sci

# Result code of the script, used to check when automatic rebuild is needed.
result=0

# Allow rebuilding the executable when first argument is `update`.
if [ "$1" == "update" ]
then
    shift
    result=222 
fi

# Run the compiled executable if it exists and rebuild is not requested.
if [ $result -eq 0 ] && [ -f $executable ]
then
    $executable $@
    result=$?
fi

# Rebuild the executable if it doesn't exist or it 
# requested a  rebuild by returning result code 222.
if [ ! -f $executable ] || [ $result -eq 222 ]
then
    rm -rf $executable CITool/build.log
    pushd $base_path > /dev/null
    swift build -c release > build.log
    build_result=$?
    popd > /dev/null

    # After rebuilding run the compiled executable
    # or display errors if the build has failed.
    if [ $build_result -eq 0 ]
    then
        $executable $@
    else
        echo
        echo Failed to build 'ci' tool. Log entries from build.log:
        echo
        cat CITool/build.log
    fi
fi
