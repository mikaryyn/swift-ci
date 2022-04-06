#!/bin/sh

result=0
executable=SwiftCI/ci/.build/release/ci

if [ "$1" == "update" ]
then
    shift
    result=222
fi

if [ $result -eq 0 ] && [ -f $executable ]
then
    $executable $@
    result=$?
fi

if [ ! -f $executable ] || [ $result -eq 222 ]
then
    rm -rf $executable SwiftCI/ci/build.log
    pushd SwiftCI/ci > /dev/null
    swift build -c release > build.log
    buildresult=$?
    popd > /dev/null

    if [ $buildresult -eq 0 ]
    then
        $executable $@
    else
        echo
        echo Failed to build 'ci' tool. Log entries from build.log:
        echo
        cat SwiftCI/ci/build.log
    fi
fi
