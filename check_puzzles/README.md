# Check Game Puzzles
Class and routines for actually running your game working to resolve the `PuzzleSolution`s provided.  Only intended to run in debug mode.

## Overview
Most interactive function, especially what have been known as text adventures, have puzzles.  Sometimes there are lots of puzzle that range from simple to complex multi-part puzzles that may have more than one solution.  While most game developers write some test code to validate a test, `checkpuzzles` takes it much further by ensuring the puzzle is reachable (the room where it is supposed to be enacted is reachable), can be triggered (a set of other conditions is met), the solution sequence is valid, and (optionally) the outcome of the puzzle is achieved.

- Puzzles are described using the `PuzzleSolution` class.
- The game is programatically played by understanding the contents of each room (where *take all* is used to fetch) as well as all of its exits and then moving randomly to connected rooms (while tracking where it has been already).
- After visiting a room (and performing a *take all* if there is something to obtain), a check is made to see if there is at least one puzzle that can be solved.  If so, it solves that best one (and validates it, if that information provided), and then resumes playing the game if there are more puzzles to solve.  If there are no more puzzles, testing ends.
- If at any point, the game is won, the automatic testing ends.
- If in visiting a room, they player fails (dies), the game backs up to prior to the death and resumes play.
- Note that **ALL** other actions such as pulling, attaching, throwing, etc. must be part of a `PuzzleSolution`.  This is not an intelligent AI-driven game tester but rather focused on ensuring the puzzles work.

## PuzzleSolution
Key to the way works are the `PuzzleSolution` definitions provided by the game developer.  While a template is provdied in `checkpuzzles.h`, the README will focus on the basic definition. There are three parts to this class.

### Puzzle ready to solve
Class properties
- `where` is a Room, Region, or list of Rooms and Regions (using [] list notation) where this puzzle can be solved.  By default, a puzzle can be solved anywhere.
- `holding` is a Thing that must be held by the player (directly or indirectly).  It can be one Thing or a list of Things (using [] list notation).  By default, the player does not need to be holding anything.
- `visible` is a Thing that must be in the Room but NOT held by the player.  It can be one Thing or a list of Things (using [] list notation).  By default, nothing needs to be in the room.
    // what needs to be absent from the room (and player as well)
    absent = nil
    // what scene needs to be active (or any scene if nil)
    during = nil
    // what other conditions must hold (regular conditional expression)
    when = true


    // commands (single-quoted strings) to execute to solve the puzzle (as needed)
    cmdList = nil
    // higher priority wins when all else is equal
    priority = 100
    // outcome can be expression OR object OR if a list, are the object(s) that must be in room
    // or on the player
    // use this hack for outcome that should not be tested
    outcome = ''


You have your text IF premium creators who create damn-near perfect content -- and you have the rest of us who sometimes miss things.  In writing any room description, your players will read what is shown in the description to figure out what to look at in more detail and/or where to go next, as expected.

A problem arises when you (as the writer) mention something in the room description that is not described  further, leading to that dreaded "I see no XXXX here" when the player enters "EXPLAIN XXXX".  This is frustrating for the player because you *just* mentioned XXXX in your room description!  Or a direction is mentioned in the room description but when the player tries to go that way, they get the confusing "You cannot go that way".

What is needed is a tool that can help identify these items (noun phrases) and exits that, as the game writer, we overlooked in providing further information, even if it is (and usually is only) atmospheric descriptions.

## Installation
- An TADS3/ADV3LITE source file `checkdescr.t` should be loaded into your environment
- In addition, one small header file `checkdescr.h` should be added before your source code -- or its definition (for debug and release) copied over to your definitions file.

## Use
### Commands
- **checkAllRoomDescr [-showall]** will create a report by scanning all rooms in your game that is written to the file `checkDescr.txt`.  By default, it will only report on rooms where it finds **noun phrases** or **directions** that are listed in the description and where *EXAMINE noun phrase* fails or *GO direction* does not work.  With the **-showall** option, it will list all noun phrases and directions found and report on their status with "OK" meaning that the associated *EXAMINE noun phrase* works or the exit is there.
- **checkRoomDescr room name** will create a report by scanning that one room with the output written to the console.  All noun phrases and exits are listed.
  
### Example Output
  Here is a sample from a recent game that was borrowed from a book on adventure game writing (and tweaked for a 10yr old) where the **-showall** option was used:
  
```
----------- wooden shack --------------
You are in a wooden shack that is sparsely populated with just a rudimentary
bed in the corner. There is an opening that leads to your yard to the north,
and a door to the east (jammed open) that heads to the center of the village.
: wooden shack : OK
: rudimentary bed : No extra description
: opening : No extra description
: yard : No extra description
: north : OK
: door : OK
: east : OK
: village : No extra description
-----------------------------------------
```
Clearly, eXamine SHOULD work for `rudimentary bed`, MAYBE should work for `opening` and `yard` (that are the same reference) as they are not there but somewhat visible, but should be IGNORED for `village` that is clearly not there.  See below on how to handle this last use case (which is a false positive; this code is not perfect and will end up with a small handful of false positives and false negatives).  After all, we do want a clean report if we run this on all rooms.  At least all of the exits mentioned actually exist.

### Customization
There are two things to customize: **word lists** and **ignoring nouns locally**.
- **Word lists**: There are a number of lists within `checkdescr.t`  you can edit. `adjs` are adjectives; `prepositions` are prepositions; `extraVerbs` are verbs and adverbs beyond the current list and `nouns` are, well, nouns.  (There are two "purge" words list that is best left alone.)  Nouns are expected to have an extra description, *especially* if preceded by an article.  They have a special format in the `nouns` list:
  - If there is a leading "-" (minus), it means the noun that should always be ignored, meaning one never expects to eXamine it.  (There is some best-guess use-case configuration in the list.) The way to **ignore nouns globally** is to **put them into the `nouns` list with a leading "-"** (minus).
  - If there is a leading "." (period), it means the noun is ambiguous -- meaning it could be a noun or a verb.  (Note that `adjs` also accepts a starting "." but it means the entry can be an adjective or a noun.)
  - If there is a "/" (slash) in the word, the part before the "/" is the singular form and the part after the "/" adds characters to make it a plural.
  - If there is a "/-" (slash) in the word, the part before the "/" is the singular form and the part after the "/-" adds characters to make it a plural AFTER the last singular character (before the "/") is removed.
- **Ignoring nouns locally** is more "surgical" as it allows you to ignore nouns on a room-by-room description basis.  This reduces noise (false positives) in a report.  To do that you add the following into your `Room` setup:
  `IGNORE_NOUNS('nounOrPhrase1'[,'nounOrPhrase2'[,...]])`
Looking at the example above, `village` does not deserve an extra description because it is simply not there; here is what the room setup looks like to solve this:
```
r1: Room 'Wooden shack'
    "You are in a wooden shack that is sparsely populated
    with <<if i3.isIn(nil)>>just a rudimentary
    <<else>>the chopped-up remains of a<<end>> bed in the corner.\b
    There is an opening that leads to your yard to the north,
    and a door to the east (jammed open) that heads to the center of the village. "
    IGNORE_NOUNS('village')
    north = r2
```
This will eliminate that noun from the report for that room.  Ideally, when you run **checkAllRoomDescr**, you should get an empty report.  (Although not shown in this example, `nounPhrase` can include the adjectives as in `rudimentary bed`.)

**NOTE:** This code is created such that **it ONLY works** in debug mode.  When you compile your game for Release, none of this code is included and `IGNORE_NOUNS(...)` is defined as nothing.

## How it works
*checkroomdescr*  is a class and a set of commands that can analyze your IF game.

- For a room (or all rooms):
  - *gPlayerChar* is put into the room first.
  - *gPlayerChar* is also made to glow such that only the "lighted room" description is seen.
  - *turnSequence()* is deflected to do nothing (so no Fuses or Daemons run) that might cause the demise of the character.
- Then, it captures the description for the room.
- Restores the *gPlayerChar* back to their original location and no longer lit up like a Christmas tree.
- The description is now post-processed to look for nouns (things that likely will be eXamined) and directions:
  - A set of ~500 of the most popular/widely-used English nouns was created using ChatGPT including their plurals and put into a list, but heavily modified to remove verbs into `extraVerbs` and distinguish *always a noun* from *ambiguously a noun*.
  - In addition, lists for articles, prepositions, adjectives, and verbs (including all **Action** verbs) are created to help further to pick out the nouns.
  - The description is also scanned looking for compass and ship-based directions (but not *in* or *out*).
  - Any nouns (or noun phrases) found in the room-specific `IGNORE_NOUNS` list are removed from the report.

This code runs fairly fast.  I do not write large games, but when the entire Colossal Cave was analyzed (~180 rooms), it took about 3 seconds -- most of which was writing `checkDescr.t` as the `-showall` option was used.

**NOTE:** One (severe?) limitation is that since "..." text is **compiled** code in TADS3, there is no way to access that within TADS3 functions.  As such, if there are any conditionals in the room description (such as in the example above), there is only one description that is emitted and evaluated (depending upon the states of the conditionals).  Sure, I could have written a Python parser to extract the original text but that just seemed too messy.  Maybe at a later date.

Please provide feedback if you have any questions or suggestions.
