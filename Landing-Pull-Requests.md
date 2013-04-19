# Landing Pull Requests

Metasploit is built incrementally by the community through GitHub's [Pull Request](https://github.com/rapid7/metasploit-framework/pulls) mechanism. Submitting pull requests (or PRs) is already discussed in the [Dev environment setup](https://github.com/rapid7/metasploit-framework/wiki/Setting-Up-a-Metasploit-Development-Environment) documentation. It's important to realize that PRs are a feature of GitHub, not git, so this document will take a look at how to get your git environment to deal with them sensibly.

# The short story

 - Configure your git environment as described [here](https://github.com/rapid7/metasploit-framework/wiki/Setting-Up-a-Metasploit-Development-Environment#keeping-in-sync).
 - Add the `fetch = +refs/pull/*/head:refs/remotes/upstream/pr/*` line to your `.git/config`.
 - When merging code from a pull request, always, always `merge --no-ff`, and write a meaningful commit message that references the original PR as `#1234` (not PR1234, not PR#1234, not 1234).
 - If you're making changes (often the case), merge --no-ff to a landing branch, then merge **that** branch to upstream/master (assuming you don't need to collaborate on changes).

# Fork and clone

First, fork and clone the `rapid7/metasploit-framework` repo, [following these instructions](https://help.github.com/articles/fork-a-repo). I like using ssh with `~/.ssh/config` aliases [as described here](https://github.com/rapid7/metasploit-framework/wiki/Setting-Up-a-Metasploit-Development-Environment#wiki-ssh), but the https method will work, too.

Once this is done, you will have a remote repository called "origin," which points to your forked repository on GitHub. You will be doing most of your work in your own fork of Metasploit, even if you have commit rights to Rapid7's fork. Now, we're going to add an "upstream" repository to talk to the Rapid7 repository.

In addition, we're going to add a magical line to the config file that will let us see all pull requests against the Rapid7 repo (both open and closed). Note that this will take a minute since you're adding some hundreds of megs to your clone's refs.

So, open up `metasploit-framework/.git/config` with your favorite editor, add an upstream remote, and add the pull request refs for both your and Rapid7's forks. In the end, you should have a section that started off like this:

````config
[remote "origin"]
  fetch = +refs/heads/*:refs/remotes/origin/*
  fetch = +refs/pull/*/head:refs/remotes/origin/pr/*
  url = https://github.com/YOURNAME/metasploit-framework
````

And now it looks like this:

````config
[remote "upstream"]
  fetch = +refs/heads/*:refs/remotes/rapid7/*
  fetch = +refs/pull/*/head:refs/remotes/rapid7/pr/*
  url = https://github.com/rapid7/metasploit-framework
[remote "origin"]
  fetch = +refs/heads/*:refs/remotes/origin/*
  fetch = +refs/pull/*/head:refs/remotes/origin/pr/*
  url = https://github.com/YOURNAME/metasploit-framework
````

Some people like to copy these over into remotes named "rapid7" and "yourusername" just so they don't have to remember about "origin" and "upstream," but for this doc, we'll just assume you have "origin" and "upstream" defined like this.

Now, you can git fetch the remote PRs. This will take a little bit, since we have a couple dozen MBs of pull request data. Storage is cheap, though, right?

````
$ git fetch --all
Fetching todb-r7
remote: Counting objects: 13, done.
remote: Compressing objects: 100% (1/1), done.
remote: Total 7 (delta 6), reused 7 (delta 6)
Unpacking objects: 100% (7/7), done.
From https://github.com/todb-r7/metasploit-framework
 * [new ref]         refs/pull/1/head -> origin/pr/1
 * [new ref]         refs/pull/2/head -> origin/pr/2
Fetching upstream
remote: Counting objects: 91, done.
remote: Compressing objects: 100% (29/29), done.
remote: Total 59 (delta 47), reused 42 (delta 30)
Unpacking objects: 100% (59/59), done.
From https://github.com/rapid7/metasploit-framework
 [... bunches of tags and PRs ...]
 * [new ref]         refs/pull/1701/head -> origin/pr/1701
 * [new ref]         refs/pull/1702/head -> origin/pr/1702
````

You can `git fetch` a remote any time, and you'll get access to the latest changes to all branches and pull requests.

# Branching from PRs

A manageable strategy for dealing with outstanding PRs is to start pre-merge testing on the pull request in isolation. For example, to work on PR #1217, we would:
````
$ git checkout origin/pr/1217
Note: checking out 'origin/pr/1217'.

You are in 'detached HEAD' state. You can look around, make experimental
changes and commit them, and you can discard any commits you make in this
state without impacting any branches by performing another checkout.

If you want to create a new branch to retain commits you create, you may
do so (now or later) by using -b with the checkout command again. Example:

  git checkout -b new_branch_name

HEAD is now at 9e499e5... Make BindTCP test more robust
((no branch)) todb@mazikeen:~/git/rapid7/metasploit-framework
$ git checkout -b landing-1217
````

Now, we're on a local branch identical to the original pull request, and can move on from there. We can make our changes, isolated from master, and then either send them back to the contributor (this requires looking up the original contributor's GitHub username and branch name on GitHub), or if there aren't any changes or the changes are trivial, we can land them (if you have committer rights to Rapid7's repo, this is where you land them to the upstream repo).

In this particular case with PR #1217, I did want to send some changes back to the contributor.

# Making changes

````
$ gvim .gitignore
[... make some changes and some commits ...]
(landing-1217) todb@mazikeen:~/git/rapid7/metasploit-framework
$ git checkout -b pr1217-fix-gitignore-conflict
Switched to a new branch 'pr1217-fix-gitignore-conflict'
(pr1217-fix-gitignore-conflict) todb@mazikeen:~/git/rapid7/metasploit-framework
$ git push origin pr1271-fix-gitignore-conflict
(pr1217-fix-gitignore-conflict) todb@mazikeen:~/git/rapid7/metasploit-framework
$ git pr-url 
https://github.com/YOURNAME/metasploit-framework/pull/new/HISNAME:HISBRANCH...YOURBRANCH
````

This sequence does a few things after editing the .gitconfig. It creates another copy of landing-1217 (which is itself a copy of upstream/pr/1217)). Next, I push those changes to my branch (todb-r7, aka "origin"). Finally, I have a mighty .gitconfig alias to spit out a copy-pastable alias to create a pull request to the original contributor's branch:

````
pr-url = !"echo https://github.com/YOURNAME/metasploit-framework/pull/new/HISNAME:HISBRANCH...YOURBRANCH"
````

Filling in the blanks (provided by the original PR's information from GitHub) gets me:

````
https://github.com/todb-r7/metasploit-framework/pull/new/schierlm:javapayload-maven...pr1217-fix-gitignore-conflict
````

I opened that in a browser, and ended up with https://github.com/schierlm/metasploit-framework/pull/1 . Once @schierlm landed it on his branch, all I (or anyone) had to do was `git fetch` to get the change reflected in origin/pr/1217, and then the integration of the PR could continue.

# Collaboration between contributors

Note the important bit here: **you do not need commit rights to Rapid7 to branch pull requests**. If Alice knows a solution to Bob's pull request that Juan pointed out, it is **easy** for Alice to provide that solution by following the procedure above. `git blame` will still work correctly, commit histories will all be accurate, everyone on the pull request will be notified of Alice's changes, and Juan doesn't have to wait around for Bob to figure out how to use `send_request_cgi()` or whatever the problem was.

# Landing to upstream

Back to PR #1217. Turns out, my change was enough to land the original chunk of work. So, someone else (@jlee-r7) was able to to do something like this:

````
$ git fetch upstream
remote: Counting objects: 12, done.
remote: Compressing objects: 100% (2/2), done.
remote: Total 7 (delta 5), reused 7 (delta 5)
Unpacking objects: 100% (7/7), done.
From https://github.com/rapid7/metasploit-framework
   9e499e5..263e967  refs/pull/1651/head -> origin/pr/1651
````

This all looked good, so he could land this to Rapid7's repo with:

````
$ git checkout -b upstream-master ---track upstream/master
$ git merge --no-ff --edit landing-1217
$ git push upstream upstream-master:master
````

The `--edit` is optional if we have our editor configured correctly in `$HOME/.gitconfig`. The point here is that we *always* want a merge commit, and we *never* want to use the (often useless) default merge commit message. For #1217, this was changed to:

````commit
Land #1217, java payload build system refactor
    
[Closes #1217]
````

# Cross-linking PRs, Bugs, and Commits

If we had a [Redmine bug](https://dev.metasploit.com/redmine/projects/framework/issues?query_id=420) we were working against, we'd mention it in this commit message as well, and we'd get a cross-reference over in Redmine. There's a special syntax for Redmine bugs, which looks like this:

````
Landing #1234 Fixing that thing

[FixRM #5678]
````

So, mentioning #1234 will create a link between this commit and the PR (you can see [PR #1217](https://github.com/rapid7/metasploit-framework/pull/1217) if you don't believe me), and mentioning `FixRM #5678` or `SeeRM #5678` will update the Redmine bug automatically.

A special phrase of "Closes #1234" will cause PR #1234 to close even if the commit doesn't actually merge everything in PR #1234 (so don't do that unless you mean it).

# Merge conflicts

The nice thing about this strategy is that you can test for merge conflicts straight away. You'd use a sequence like:

````
git checkout upstream/pr/1234
git checkout -b landing-1234
git checkout master
git checkout -b master-temp
git merge landing-1234 master-temp
````

If that works, great, you know you don't have any merge conflicts right now.

# Questions and Corrections

Bug @todb-r7, either on Freenode on the #metasploit channel (he's todb there), or by e-mailing the [metasploit-hackers](https://lists.sourceforge.net/lists/listinfo/metasploit-hackers) mailing list.