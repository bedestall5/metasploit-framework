Using **two-space soft tabs**, and not hard tabs, is the second precept<sup>*</sup> of the [Ruby Style Guide](https://github.com/bbatsov/ruby-style-guide#source-code-layout). This convention is widely adopted by nearly all Ruby projects, with Metasploit as of August of 2013 being the only major exception that we can think of.

We are looking to change this.

While we expect a fair amount of code conflict during the transition, we will have in place tools and procedures to quickly unconflict new submissions that prefer the current (old) style of hard tabs -- for the timeline to implementation, see below. By the end of 2013, the Metasploit Framework (and related projects) should be consistent with the rest of the Ruby world.

**TL;dr**: Please pardon our dust as we renovate Metasploit for your convenience.

 <sup>*The first precept is UTF-8 encoding for source files, but we're going to keep ignoring that one for now since it monkeys with regexing over binary strings, which we do a lot. :)</sup>

## Implementation Timeline

Items struck out are complete.

### By August 15, 2013
 - ~~Add a retabbing utility~~
 - ~~Update msftidy.rb to respect spaces or tabs, but not mixed.~~
 - ~~Add a test case~~
 - ~~Land [PR #2197](https://github.com/rapid7/metasploit-framework/pull/2197) which provides the above.~~
 - Ask CoreLan (sinn3r) to update mona.py templates to use spaces, not tabs.
 - Verify mona.py's update.

Note that once [PR #2197](https://github.com/rapid7/metasploit-framework/pull/2197) lands, we will no longer be enforcing any particular tab/space indentation format until about October 8, when we switch for real to soft tabs.

### By August 28, 2013
 - Write a procedure for offering retabbing to outstanding pull requests.
 - Retab modules directory as [@tabassassin](https://github.com/tabassassin) using `retab.rb`
 - Retab libraries as [@tabassassin](https://github.com/tabassassin) using `retab.rb`.
 - Offer retabbing to outstanding pull requests in the form of outbound PRs from [@tabassassin](https://github.com/tabassassin).

### By September 18, 2013
 - Periodically retab as [@tabassassin](https://github.com/tabassassin) to catch stragglers that snuck in.
 - Periodically offer retabbing services as [@tabassassin](https://github.com/tabassassin) as above.
 - Write a procedure for retabbing incoming pull requests upon landing, per committer (don't bother with blocking on [@tabassassin](https://github.com/tabassassin) doing the work).

### By October 8
 - Convert msftidy.rb to enforce spaces only, warn about hard tabs.
 - Prepare for the onslaught of new code from experienced Ruby software devs who are no longer offended by our hard tabs.

## Changes or comments

Please bug [@todb-r7](https://github.com/todb-r7) if you have questions, or especially if you notice gaps in this plan. For example, I see right now there's no specific callout for rspec verification of spaces vs tabs, and that should run on at least a sample of modules and libraries as part of the retabbing exercise.