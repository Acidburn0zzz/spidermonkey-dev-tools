#!/bin/sh -e

# These paths are relative to $hgrepo
lockfile=./.hg/sync.lock
gitClone=./.hg/git
repoPath=./.hg/repos
bridgePath=./.hg/bridge
hgConf=./.hg/hgrc
pullFlag=./.hg/pull.run

usage() {
    echo 1>&2 'pull.sh <hgrepo>

Import mercurial modifications and transfer then to each master branch of
git repository and tries.'
    exit 1
}

test $# -ne 1 && usage;
hgrepo=$1

cd $hgrepo;
hgrepo=$(pwd)
test -d $bridgePath

# Return the list of repositories from which data are fetched.  This sed
# script extract the data from the list of paths of the hgrc file.
getPullRepos() {
    sed -n '
      /^\[paths\]$/ {
        :newline;
        n;
        /^ *#/ { b newline; };
        /=/ {
          s/=.*//;
          /-pushonly/ { b newline; };
          p;
          b newline;
        }
      }' $hgConf
}

getPushRepos() {
    sed -n '
      /^\[paths\]$/ {
        :newline;
        n;
        /^ *#/ { b newline; };
        /=/ {
          s/ *=.*//;
          /-pushonly$/ { s/-pushonly$//; p; b newline; };
          b newline;
        }
      }' $hgConf
}


# Create a repository which map
createGitRepo() {
    local repo=$1
    local pushOnly=$2
    local edgeName=$repo

    echo "Create repository $edgeName"
    if test $pushOnly = true; then
        edgeName=$repo-pushonly
    fi

    # Update the git-repo from the git-bridge.
    GIT_DIR=$repoPath/$repo
    export GIT_DIR

    mkdir -p $GIT_DIR
    git init --bare
    git remote add origin $gitClone
    # Ensure this repository only fetch its corresponding master branch.
    git config --replace-all remote.origin.fetch "+refs/heads/$edgeName/master:refs/heads/master"

    # We do not put the name under /refs/heads such as other user
    # won't see the next attempt to commit to the master of
    # mercurial.
    git config --add remote.origin.push "+refs/push/master:refs/heads/$edgeName/push"

    # Set hooks to accept pushes.
    git config --add hooks.bridge.location "$hgrepo"
    git config --add hooks.bridge.edgeName "$edgeName"
    git config --add hooks.bridge.pushOnly "$pushOnly"
    mkdir -p $repoPath/$repo/hooks
    cp $bridgePath/push.sh $repoPath/$repo/hooks/update
    chmod u+x $repoPath/$repo/hooks/update
}

# Get one repository name and look if there is any pending modification. If
# they are, then the tip would be updated by the next pull. After the pull
# the tip is assumed to be the last changeset downloaded, and thus the head
# of master branch of the repository. To avoid any reset of the tip while
# doing these modifications we have to lock the repository.
updateFromRepo() {
    local edgeName=$1

    echo "$edgeName: Looking for update from $(hg paths $edgeName)."
    local branch=$edgeName/master
    local tip=$(hg identify $(hg paths $edgeName))

    # Check if the current repository has the changeset.
    if desc=$(hg log -r $tip --template '[ {bookmarks} ]' 2>/dev/null); then

        # We found the master branch at the same location of the tip, we can
        # skip the rest of the update procedure.
        if echo $desc | grep -c " $branch " >/dev/null; then
            echo "$edgeName: No update needed."
            return 0;
        fi

    else
        echo "$edgeName: Pull changes."

        # If the remote tip is not among the changeset of the repository, then
        # pull changes of the remote repository.
        hg incoming --bundle .hg/incoming.bundle $edgeName

        ( flock -x 10;

        # Pull latest changes.
          hg pull $edgeName

        ) 10> $lockfile
    fi

    echo "$edgeName: Import changes into git."

    # The double lock gives the priority to the pusher and avoid locking
    # concurrent git repositories.
    ( flock -x 11;
    ( flock -x 10;

    # Reset the bookmark to the remote tip.
      hg bookmark -f $branch -r $tip

    # Update the git repository.
      hg gexport

    ) 10> $lockfile

    # Update the git-repo from the git-bridge.
    if ! test -d $repoPath/$edgeName; then
         createGitRepo $edgeName false
    fi
    GIT_DIR=$repoPath/$edgeName git fetch origin

    ) 11> $lockfile.$edgeName

    echo "$edgeName: Update complete."
}

# create push repositories
for edgeName in $(getPushRepos); do
    if ! test -d $repoPath/$edgeName; then
        createGitRepo $edgeName true
    fi
done

# Check if there is any pending changes.
for edgeName in $(getPullRepos); do
    updateFromRepo $edgeName
done
