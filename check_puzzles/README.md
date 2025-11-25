# Check Game Puzzles
Class and routines for actually running your game working to resolve the `PuzzleSolution`s provided.  Only intended to run in debug mode.

## Overview
Most interactive function, especially what have been known as text adventures, have puzzles.  Sometimes there are lots of puzzle that range from simple to complex multi-part puzzles that may have more than one solution.  While most game developers write some test code to validate a test, `checkpuzzles` takes it much further by ensuring the puzzle location is reachable (the room where it is supposed to be enacted can be traveled to via normal commands), can be triggered (a set of other conditions is met), the solution sequence is valid, and (optionally) the outcome of the puzzle is achieved.

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
- `absent` is a Thing that must NOT be in the Room or held by the player.  It can be one Thing or a list of Things (using [] list notation).  By default, nothing is considered absent.
    // what scene needs to be active (or any scene if nil)
- `during` is a Scene (or list of Scenes) that are active in order to solve the puzzle.  By default, any Scene (or none at all) will work.
- `when` is an additional arbitrary expression that must be true for the puzzle to be solved. By default, it is true.

### Actions to solve the puzzle
With the puzzle solution now "triggered" such that it can be enacted, two other terms now come into play:
- `cmdList` is a list of one or more commands that are executed to perform the puzzle solution (e.g. "OPEN DOOR WITH RED KEY").  It is possible but highly unlikely there would be no commands given such as solving a puzzle just be entering a room.
- `priority` is the priority given to the specific puzzle.  During a given puzzle analysis step (after each move/action), a check is made of the puzzles.  The first unsolved puzzle encountered in the list is chosen by default.  So, in general, if you create your set of `PuzzleSolution` instances in the order you want to solve them, they would work.  However, setting the priority means that the puzzle encountered first or has the highest priority (where a higher number if a higher priority) means that puzzle will be solved first.

### Testing the puzzle is solved
A puzzle being solved usually means something has changed such as a door unlocked, a new object shows up (and perhaps one or more disappear), etc.  You can test that the outcome of the puzzle solution is as expected:
- `outcome` defines the outcome expected.  In its simplest form it is just an object that you expect to now be in the room.  It could also be a list of objects.  Finally, it can be an expression that evaluates to true if the outcome is correct.  (Note that you cannot use the template shorthand for `outcome` when it is an arbitrary boolean expression.)

## Installation
- An TADS3/ADV3LITE source file `checkpuzzles.t` should be loaded into your environment
- In addition, one small header file `checkpuzzles.h` should be added before your source code -- or its template copied over to your definitions file.

## Use
### Command
- **checkPuzzles** will start running the game and work through the puzzles.  Once the game is won or all puzzles are solved, it will finish.  A SCRIPT file is written out called `checkpuzzles.txt` with the full activity (although you can just watch your TADS console as well).  *You should only run this command at startup or after restart!*
  
### Example
There is a game written based upon a book on Adventure game writing I bought called "..." by ....  The game was tweaked for a 10/11 year old to play but the puzzles were largely left intact.  Here are three puzzle examples in the game:
- You open the castle drawbridge by throwing a rope with anchor attached into an opening above the closed drawbridge, then pulling on the rope.
- The rope with anchor is attached to a rotten boat at the nearby river.  It can only be freed (taken) by cutting the rope with a broken piece of pottery.
- You have a jug that you use for water (to solve one puzzle) but then break it to get the pottery piece.

Let's see what those puzzle entries look like, starting with the template for the `PuzzleSolution`.
```
PuzzleSolution template [cmdList] +priority? *holding|[holding]? &visible|[visible]? -absent|[absent]? 
    @where|[where]? ->outcome|[outcome]? ;
```

Of course, in reality, you need to solve these puzzles in the opposite order as shown above.
```
// need sharp object to cut rope
// we do this by breaking the jug -- which we must have in
// our possession.  we do not care where this is done.
// we specify the honeycomb as well ONLY because we do not
// want the break the jug until its earlier task of carrying
// water is done -- and that is only confirmed if you are
// carrying the honey (not strictly true but close enough).
// note the outcome is that pottery is created
//
PuzzleSolution ['break jug'] *[jug,honeycomb] ->pottery;

// always best to finish all necessary steps
// yes, it would fetch the rope later but just do it to
// truly complete the puzzle
// note that we have to be holding the pottery and have to
// be where the rotten boat is located
// the outcome here is a test that we are now holding the rope
PuzzleSolution ['cut rope with pottery','get rope'] *pottery @westriverbank
    outcome = rope.isHeldBy(me)
;

// now we can take care of the drawbridge
// have to be holding the rope to start and be at the moat
// where the drawbridge is closed.  It gets replaced by the
// open drawbridge when done
PuzzleSolution ['throw anchor at drawbridge','pull rope'] *rope &closed_drawbridge @moat ->opened_drawbridge ;


Please provide feedback if you have any questions or suggestions.