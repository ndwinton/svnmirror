#!/bin/bash

# uniqueName(prefix)
#
# Generate a unique name, based on the date and a counter, prefixed with the
# supplied prefix string.
#
COUNTER_FILE=/tmp/$$-counter
echo 0 > $COUNTER_FILE

function uniqueName() {
    local count=$(< $COUNTER_FILE)
    ((count = count + 1))
    echo $count > $COUNTER_FILE
    echo "$1-$(date '+%Y%m%d%H%M%S')-$count"
}

# addNewFile(prefix)
#
# Generate a new file in the current directory and add it to version control.
#
function addNewFile() {
    local name=$(uniqueName $1)
    echo "Content: $name" >> $name
    svn add --quiet $name
    svn commit --quiet -m "added $name" $name
    echo $name
}

# addNewFileNoCommit(prefix)
#
# Generate a new file in the current directory and schedule for addition.
#
function addNewFileNoCommit() {
    local name=$(uniqueName $1)
    echo "Content: $name" >> $name
    svn add --quiet $name
    echo $name
}

function fatal() {
    echo "ERROR: $*" >&2
    exit 1
}

function verify {
    cd $BASE
    rm -rf src-export dst-export
    
    echo "Verify - $*"
    
    svn --quiet export $SRCMIRROR src-export
    svn --quiet export $DSTMIRROR dst-export

    diff -c -r src-export dst-export || fatal "$* - Export comparison failed"
    svn ls -R --xml $SRCROOT/from | grep -v 'revision=' | grep -v "$SRCROOT/from" > src.ls
    svn ls -R --xml $DSTROOT/to | grep -v 'revision=' | grep -v "$DSTROOT/to" > dst.ls

    diff -c src.ls dst.ls || fatal "$* - Recursive ls comparison failed"
    
    svn pl $DSTROOT/to | grep -q 'test-property' || fatal "$* - Directory property not found"
}

SCRIPTDIR=$(cd $(dirname $0); pwd)

BASE=$PWD/test-tmp
rm -rf $BASE
mkdir $BASE

SRC=src

DST=dst

echo "Setting up initial repository ..."

svnadmin create $BASE/$SRC
svnadmin create $BASE/$DST
# Allow revprop changes in the destination repp
ln -s /bin/true $BASE/$DST/hooks/pre-revprop-change

SRCROOT=file://$BASE/$SRC
DSTROOT=file://$BASE/$DST

SRCMIRROR=$SRCROOT/from
DSTMIRROR=$DSTROOT/to

cd $BASE

svn --quiet mkdir $SRCROOT/unmirrored -m 'Create unmirrored path'
svn --quiet mkdir $SRCROOT/from -m 'Create mirrorred path'

SRCWC=$BASE/$SRC-wc
svn --quiet checkout $SRCROOT $SRCWC

# unmirrored directory -- content here will not be mirrored
# but transactions will bump the revision count.
cd $SRCWC/unmirrored

# from directory -- content here will be mirrored
cd $SRCWC/from
# Add some basic content
file=$(addNewFile mirrored)
svn --quiet update
svn --quiet propset test-property hello .
svn --quiet mkdir subdir
svn --quiet commit  -m 'New mirrored sub-directory'

# Interleave some unmirrored transactions
cd $SRCWC/unmirrored
svn --quiet mkdir subdir
svn --quiet commit -m 'New unmirrored sub-dir' --username Tom

# Add a new file in the (mirrored) sub directory and save the name for later
# modification
cd $SRCWC/from/subdir
file=$(addNewFile insub)
svn --quiet move $file $file.renamed
svn commit --quiet -m "Rename $file"
modfile=$(addNewFile insub)

# Various copy operations, with or without modification of contents
cd $SRCWC
svn --quiet update
svn --quiet copy unmirrored/subdir from/outside
svn --quiet commit -m 'Copy from outside' --username Dick

svn --quiet copy from/subdir from/subdir-copy-1
svn --quiet commit -m 'Copy within' --username Harry

svn --quiet copy from/subdir from/subdir-copy-2
cd $SRCWC/from/subdir-copy-2
echo modified >> $modfile
cd $SRCWC
svn --quiet commit -m 'Copy dir with modify file' --username Alice

# Now test of copy-and-modify of a simple file.
cd $SRCWC/from
addfile=$(addNewFile copy)
svn --quiet copy $addfile $addfile-copy
echo modified >> $addfile-copy
svn --quiet commit -m "Copy and modify individual file" --username Bob

# Copy from mirrored tree to outside the tree (should be a no-op for
# the mirroring process)
cd $SRCWC
svn --quiet copy from/subdir outside
svn --quiet commit -m 'Copy outside' --username Charlie

cd $BASE

svn --quiet mkdir $DSTROOT/other -m 'Create non-target dir'
svn --quiet mkdir $DSTMIRROR -m 'Create target mirror dir'

echo "Mirroring ..."

perl -MDevel::Cover=-silent,1 $SCRIPTDIR/svnmirror.pl --copy-revprops=all $SRCMIRROR $DSTMIRROR

verify "Phase 1"

cd $SRCWC/from
file=$(addNewFile newfile)
cd subdir
file=$(addNewFile newfile)
cd $SRCWD
svn --quiet copy subdir subdir-copy-3
svn commit --quiet -m 'Copy dir again'

echo "Mirroring again ..."

cd $BASE
perl -MDevel::Cover=-silent,1 $SCRIPTDIR/svnmirror.pl --copy-revprops=all $SRCMIRROR $DSTMIRROR

verify "Phase 2"

cd $SRCWC/from/subdir
delfile=$(addNewFile togo)
file=$(addNewFile new)
svn --quiet rm $delfile
svn commit --quiet -m "Deleted $delfile"
cd $SRCWC/from
svn --quiet move subdir-copy-1 renamed
svn commit --quiet -m 'Dir rename'

cd $BASE

echo "Mirroring (with new working copies) ..."
perl -MDevel::Cover=-silent,1 $SCRIPTDIR/svnmirror.pl --source-working-dir=wd.src --target-working-dir=dst.wd --copy-revprops=all $SRCMIRROR $DSTMIRROR

verify "Phase 3"

cover
echo "*** All tests completed OK ***"
