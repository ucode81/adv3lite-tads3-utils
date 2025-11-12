#charset "us-ascii"

#ifdef __DEBUG

// set this to see how the individual words in a description are being parsed up
// #define DEBUG_PARSER_MAP

/*
 *   One of the difficulties of creating text adventure is to ensure you have covered "all
 *   of the corners".  What that means is often there are descriptions -- particularly in
 *   rooms -- where some <noun> is referenced, but when the user attempts to EXAMINE that
 *   <noun>, they get the message something along the lines of "I see no <noun>".
 *
 *   This code along with two debug commands walks through all room descriptions to see if
 *   all of the objects are understand -- meaning that EXAMINE works on it.  It reports
 *   for each room (or for a single room) which objects are not understood.  It also ensures
 *   that all exits mentioned in the room description are actually present as exits.
 *
 */

#include "advlite.h"
#include "lookup.h"

// thought about using enums but this appears to be faster
#define DESCR_WORD_NOUN 0
#define DESCR_WORD_PREP 1
#define DESCR_WORD_VERB 2
#define DESCR_WORD_ART 3
#define DESCR_WORD_UNKNOWN 4
#define DESCR_WORD_IGNORE 5
#define DESCR_WORD_VERBORNOUN 6
#define DESCR_WORD_PUNCT 7
#define DESCR_WORD_YOU 8
#define DESCR_WORD_DIR 9
#define DESCR_WORD_PURGE 10
#define DESCR_WORD_ADJ 11
#define DESCR_WORD_ADJORNOUN 12
#define DESCR_WORD_PURGEHARD 13

/* per Eric Eve suggestion to reduce unnecessary warnings */
property ignore_nouns;

/*
 *   This section handles parsing up the output messages from a room description.
 *
 *   It is not pretty, but it does the job.
 *
 */

class checkDescrObjError: Exception
    displayException() { "Evaluate tokenizer exception -- unable to parse"; }
;

checkDescrObjTokenizer: Tokenizer
    rules_ = static
    [
        /* skip whitespace */
        ['whitespace', R'<Space>+', nil, &tokCvtSkip, nil],

        /* 
         *   Words - note that we convert everything to lower-case.  A
         *   word can start with any letter or number and then
         *   alphabetics, digits, hyphens, and apostrophes after that. (tokWord,tokString)
         */
        ['word', R'<AlphaNum>(<AlphaNum>|([-\']<AlphaNum>))*', tokWord, &tokCvtLower, nil],
        
        // handle , as a separate item for conversations
        ['punc', R'([-.,;:?&!_%()<>{}*/+]|<lsquare>|<rsquare>)+', tokPunct, nil, nil],
        
        /* 
         *   Single-quoted and double-quoted strings are NOT searched for nouns for now
         */
        ['string', R'\"[^"]+\"', tokString, nil, nil],
        ['string', R'\'[^\']+\'', tokString, nil, nil]
    ]
;

checkDescrObj: object
    wordMap = nil   // where all the words we know about get stored
        
    // Map of direction properties to their command names
    dirs = [
        &north -> 'north',
        &south -> 'south',
        &east -> 'east',
        &west -> 'west',
        &up -> 'up',
        &down -> 'down',
//        &in -> 'in',      // cannot use this one as too ambiguous
//        &out -> 'out',    // likewise here
        &northeast -> 'northeast',
        &northwest -> 'northwest',
        &southeast -> 'southeast',
        &southwest -> 'southwest',
        &fore -> 'fore',
        &aft -> 'aft',
        &port -> 'port',
        &starboard -> 'starboard'
    ]

    // initialize the dictionary used by this code base
    init()
    {
        if(wordMap == nil) {
            local v;
            wordMap = new LookupTable(1024,1024);
            
            // not really just prepositions, but for the purposes of finding nouns, it works
            foreach(v in prepositions)
                addToWordMap(v,DESCR_WORD_PREP);
            // these are first-class citizens that ensure we have a noun coming
            foreach(v in articles)
                addToWordMap(v,DESCR_WORD_ART);
            // known words in the game to ignore
            foreach(v in ['you','me','i'])
                addToWordMap(v,DESCR_WORD_YOU);
            // verbs beyond the action verbs
            foreach(v in extraVerbs)
                addToWordMap(v,DESCR_WORD_VERB);
            // adjectives
            foreach(v in adjs) {
                if(v.startsWith('.'))
                    addToWordMap(v.substr(2),DESCR_WORD_ADJORNOUN);
                else
                    addToWordMap(v,DESCR_WORD_ADJ);
            }
            // directions are another thing to find
            foreach(v in dirs.valsToList()) {
                addToWordMap(v,DESCR_WORD_DIR);
                addToWordMap(v+'ward',DESCR_WORD_DIR);
            }
            
            // special words that could be noun or verb but lop off ALL actions
            foreach(local v in purgeWords) {
                addToWordMap(v,DESCR_WORD_PURGE);
            }
            foreach(local v in hardPurgeWords) {
                addToWordMap(v,DESCR_WORD_PURGEHARD);
            }

            // add the known action verbs
            v = firstObj(Action);
            while (v != nil) {
                // not including any system commands, only verbs that are actions in game
                if(v.verbRule != nil && v.turnsTaken != 0 && v.includeInUndo) {
                    local vp = v.verbRule.verbPhrase;
                    if(vp != nil) {
                        local i = vp.find('/');
                        if(i != nil)
                            vp = vp.substr(1,i-1);
                        i = vp.find('(');
                        if(i != nil)
                            vp = vp.substr(1,i-1);
                        vp = vp.trim();
                        if(purgeWords.indexOf(vp) == nil)
                            addToWordMap(vp,DESCR_WORD_VERB);
                    }
                }
                v = nextObj(v,Action);
            }
            
            // add the nouns
            foreach(local n in nouns) {
                local ntype = DESCR_WORD_NOUN;
                // starts with . means ambiguous, starts with - means a hard ignore
                if(n.startsWith('.') || n.startsWith('-')) {
                    ntype = n.startsWith('.')? DESCR_WORD_VERBORNOUN : DESCR_WORD_IGNORE;
                    n = n.substr(2);
                }

                // a slash helps us declare the plural of the noun with fewer chars
                local i = n.find('/');
                if(i == nil)
                    addToWordMap(n,ntype);
                else {
                    local n2 = n.substr(1,i-1);
                    addToWordMap(n2,ntype);
                    // a /- means to strip off the last char of the base word first
                    if(n.find('/-') == i)
                        n = n.substr(1,i-2) + n.substr(i+2);
                    else
                        n = n2 + n.substr(i+1); 
                    addToWordMap(n,ntype);
                }
            }
        }
    }

    addToWordMap(val,vtype)
    {
        local scmp = new StringComparator(nil,true,nil);    // case-sensitive as lower anyway
        local hash = scmp.calcHash(val);
        local vlist = [val,vtype];
        if(wordMap.isKeyPresent(hash)) {
            foreach(local n in wordMap[hash]) {
                if(val.compareTo(n.car()) == 0) {
                    // cannot get verbs quite right -- so just skip repeats!
                    if(n.cdr().car() == vtype && vtype == DESCR_WORD_VERB)
                        return;
                    // You REALLY should fix any collisions but are not forced to do so
                    // The first one always wins
                    "Collision: <<val>> of type <<vtype>> collides with previous type
                    <<n.cdr().car()>>\n";
                    return;
                }
            }
            wordMap[hash] = wordMap[hash].append(vlist);
        } else {
            wordMap[hash] = [vlist];
        }
    }
    
    /*
     *   This allows us to redirect the "..." output strings so we can capture the text.
     *   It is the ONLY way to capture "..." strings programatically as they are actual
     *   game code, and using an external program such as Python to extract would work
     *   but wanted to stay within the eco-system
     */
    sayText = ''            // buffer to hold the value
    captureSayText = nil    // are we actually capturing; if so, disable turnSequence, too
    addSayText(txt)
    {
        sayText += txt;
    }
    
    
    /*
     *   Execute a command string programmatically
     */
    executeCommand(cmdStr)
    {
        if (cmdStr == nil || cmdStr == '')
            return nil;
        
        try {    
            // start the capture process
            captureSayText = true;
            sayText = '';
            // Use Parser.parse to execute the command
            Parser.parse(cmdStr);
            // end the capture process
            captureSayText = nil;
            return sayText;
        } catch (Exception ex) {
            // Ignore parsing/execution errors - we want to continue exploring
        }
        finally {
        }           
        return nil;
    }
    
    // extract phrase from token list
    extractPhrase(toks,start,end)
    {
        local lst = [];
        if(start == 0)
            start = end;
        while(start <= end) {
            lst = lst.append(toks[start][1]);
            ++start;
        }
        return lst.join(' ');
    }
    
    // find the nouns
    findNouns(toks)
    {
        // these words are look-ahead and wipe out any phrase even if a noun before
        local adjmaybe = 0, adj = 0, v, nlist = [];
        local gotArt = nil, gotAdjNoun = nil, gotNounVerb = nil;
        local unkIdx = 0;
        
        for(local i in 1..toks.length()) {
            v = toks[i];
            switch(v[2]) {

            case DESCR_WORD_DIR:
                // reset first!
                adj = adjmaybe = unkIdx = 0;
                gotArt = gotAdjNoun = gotNounVerb = nil;
                if(v[1].endsWith('ward'))
                    toks[i][1] = v[1].substr(1,-4);
                // INTENTIONAL FALL THRU
                
            case DESCR_WORD_NOUN:
                // hard purge words wipe out the pending noun as a look-ahead
                if(i != toks.length() && toks[i+1][2] != DESCR_WORD_PURGEHARD) {
                    if(adj == 0)
                    {
                        if(adjmaybe != 0)
                            adj = adjmaybe;
                        else if(unkIdx != 0)
                            adj = unkIdx;
                        else
                            adj = i;
                    }
                    nlist += extractPhrase(toks,adj,i);
                    ++i;    // skip next as must be verb or similar
                }
                // INTENTIONAL FALL THRU
                
            case DESCR_WORD_PURGEHARD:
                // reset
                adj = adjmaybe = unkIdx = 0;
                gotArt = gotAdjNoun = gotNounVerb = nil;
                break;

            case DESCR_WORD_ART:
                adj = unkIdx = 0;
                adjmaybe = i + 1;   // next word could be noun or adjective
                gotArt = true;  // definitely a noun coming!
                gotAdjNoun = gotNounVerb = nil;
                break;
                
            case DESCR_WORD_ADJ:
                if(adj == 0) {
                    if(adjmaybe != 0) {
                        adj = adjmaybe;
                        adjmaybe = 0;
                    }
                    else
                        adj = i;
                }
                gotAdjNoun = gotNounVerb = nil;
                break;

            case DESCR_WORD_ADJORNOUN:
                if (gotAdjNoun) {
                    // since cannot have two nouns in a row, the last one must be an adj
                    if(adj == 0)
                        adj = adjmaybe;
                } else {
                    gotAdjNoun = true;
                    adjmaybe = i;
                }
                gotNounVerb = nil;  // this state now meaningless
                break;
                
            case DESCR_WORD_VERBORNOUN:
                // might be a noun but cannot be if last one was
                if(gotAdjNoun) {
                    // SOOOO, last one could be adjective OR noun!
                    // look ahead to next one to see what to do
                    local n = i;
                    if(i != toks.length()) {
                        v = toks[i+1];
                        switch(v[2]) {
                        // LAST one was our noun (and this one is our verb)
                        case DESCR_WORD_NOUN:
                        case DESCR_WORD_ART:
                        case DESCR_WORD_DIR:
                        case DESCR_WORD_ADJ:
                        case DESCR_WORD_PREP:
                        case DESCR_WORD_YOU:
                            n = i - 1;
                            break;
                            
                        // THIS is our noun!
                        case DESCR_WORD_PUNCT:
                        case DESCR_WORD_VERB:
                        case DESCR_WORD_VERBORNOUN:
                            break;
                            
                        default:
                            n = 0;  // no clue so move on
                            break;
                        }
                    }
                    if(n != 0) {
                        // found noun
                        if(adj == 0)
                            adj = n;
                        if(gotArt)
                            adj = adjmaybe;
                        nlist += extractPhrase(toks,adj,n);
                        ++i;    // skip next word
                        // reset except for noun
                        adj = adjmaybe = unkIdx = 0;
                        gotArt = gotAdjNoun = gotNounVerb = nil;
                    }                        
                } else {
                    gotNounVerb = true;
                }
                break;
                
            case DESCR_WORD_UNKNOWN:
                if(unkIdx == 0)
                    unkIdx = i;     // keep track of first one
                gotNounVerb = gotAdjNoun = nil;
                break;

            case DESCR_WORD_PURGE:
                gotArt = nil;
                // INTENTIONAL FALL THRU
                
            case DESCR_WORD_IGNORE:
                gotNounVerb = gotAdjNoun = nil;
                // INTENTIONAL FALL THRU
                
            case DESCR_WORD_VERB:
            case DESCR_WORD_PREP:
            case DESCR_WORD_YOU:
            case DESCR_WORD_PUNCT:
                if(gotArt || gotNounVerb || gotAdjNoun) {
                    if((adjmaybe != 0 && adjmaybe <= i - 1) || (adj != 0 && adj < i-1) ||
                        (adjmaybe == 0 && adj == 0 && v[2] == DESCR_WORD_VERB)) {
                        nlist = nlist.append(extractPhrase(toks,
                            adjmaybe < adj? adj : adjmaybe,i-1));
                        // already automatically skipping next
                    }
                }
                // if next must be verb, skip it!
                if(v[2] == DESCR_WORD_YOU)
                    ++i;
                adj = adjmaybe = unkIdx = 0;
                gotArt = gotAdjNoun = gotNounVerb = nil;
                break;
            
            default:
                "### SHOULD NEVER GET HERE ###!\b";
                abort;
            }
        }
        return nlist.getUnique();
    }

    /*
     *   Check the room description
     */
    checkDescrRoom(room,showAll)
    {
        local olocn = gPlayerChar.location;
        local olit = gPlayerChar.isLit;
        
        if (room == nil || !room.ofKind(Room))
            return nil;
        
        // initialize in case not done yet
        init();

        // Make sure we're in this room
        if (gPlayerChar.location != room) {
            try {
                // future planning for execution
                gPlayerChar.moveInto(room);
                gPlayerChar.isLit = true;   // pretend this is the light source
            } catch (Exception ex) {
                // Ignore - might not be able to move here
                "ERROR: Cannot enter room <<room.roomTitle>>\n";
                return nil;
            }
        }
        
//        "Examining room <<room.roomTitle>>\n";
        
        // now get the room description
        sayText = '';
        captureSayText = true;
        room.desc;
        local d = sayText;
        captureSayText = nil;
       
        // time to have fun with the captured output; turn all non-space into single space
        // could not get findReplace to work properly either, so just focused on ASCII
        // characters AFTER converting from HTML back to text
        
        //    d = d.findReplace(R'[^-a-zA-z0-9_.;,/?\'"()<>]+',' ',ReplaceAll);
        //    d = d.findReplace(R'<^AlphaNum|lparen|rparen|lsquare|rsquare|lbrace|rbrace|langle|rangle|caret|period|comma|squote|dquote|star|plus|percent|question|dollar|;|%-|_>',' ');
        local s = new StringBuffer(1000,1000);
        s.append(d.specialsToText().trim());
        d = '';
        local i, v, w, val, m, ival;
        m = nil;
        // everything that is not a printable char in ASCII is turned into a space
        for(i in 1..s.length()) {
            v = s.charAt(i);
            if(v > 32 && v < 127) {
                d += s.substr(i,1);
                m = nil;
            }
            else if(!m) {   // limits spaces to one
                m = true;
                d += ' ';
            }
        }
        // turn it into tokens
        local toks = checkDescrObjTokenizer.tokenize(d);
        local scmp = new StringComparator(nil,true,nil);    // case-sensitive as lower anyway
        for(i in 1..toks.length()) {
            // convert each token into the new type if it is a word
            if(toks[i][2] == tokWord) {
                w = toks[i][1];
                v = scmp.calcHash(w);
                if(wordMap.isKeyPresent(v)) {
                    // now need to look at the list
                    foreach(val in wordMap[v]) {
                        if(w.compareTo(val[1]) == 0) {
                            toks[i][2] = val[2];
                            w = nil;    // means success!
                            break;
                        }
                    }
                    if(w == nil)
                        continue;
                }
                // verb or adverb
                if(w.length() > 3 && (w.endsWith('ed') || w.endsWith('ly')))
                    toks[i][2] = DESCR_WORD_ADJ;
                else
                    toks[i][2] = DESCR_WORD_UNKNOWN;
            } else if(toks[i][2] == tokString) {
                toks[i][2] = DESCR_WORD_IGNORE;
            } else {
                toks[i][2] = DESCR_WORD_PUNCT;
            }
        }
        
        // reset the stringbuffer to be the stripped string
        s.deleteChars(1);
        s.append(d);
        // fix the room description for 72 or so length line
        if(fileHdl != nil) {
            i = 1;
            while(i < s.length()) {
                i += 72;
                while(i < s.length() && s[i] != ' ')
                    ++i;
                if(i >= s.length())
                    break;
                s[i] = '\n';
            }
        }
        // now how to get things set up for the report
        d = toString(s);
        s.deleteChars(1);
        i = '----------- ' + room.name + ' --------------\n';
        s.append(i);
//        s.insert(d,1);    // Stringbuffer insert not working -- complains not an int!
        s.append(d);
        s.append('\n- - - - - - - - - - - -\n');
#ifdef DEBUG_PARSER_MAP
        // dump the description terms -- for debugging only
        ival = ['n','p','v','a','o','x','n,v','.','=','*','P','j','j,n'];
        foreach (val in toks) {
            s.append(val[1] + '[' + ival[val[2]+1] + '] ');
        }
        s.append('-----\n');
#endif

        // first get the nouns associated with the description
        ival = checkDescrObj.findNouns(toks);
        
        /* Now attempt to EXAMINE nouns one at a time */
        local haveMissing = nil;
        local dirlist = dirs.valsToList();
        local exitList = getExitDirs(room);
        local ignoreList = room.ignore_nouns;
        foreach(val in ival) {
            // skip any nouns in the list
            if(ignoreList != nil && ignoreList.indexOf(val) != nil)
                continue;
            i = ': ' + toString(val) + ' : ';
            if(dirlist.indexOf(val) != nil) {
                if(exitList.indexOf(val) != nil) {
                    if(showAll)
                        s.append(i + 'OK\n');
                } else {
                    s.append(i + 'Exit not found\n');
                }
            } else {
                m = 'X ' + toString(val);
                v = executeCommand(m);
                if(v.find(' see no ') == nil)  {
                    if(showAll)
                        s.append(i + 'OK\n');
                } else {
                    s.append(i + 'No extra description\n');
                    haveMissing = true;
                }
            }
        }
        if(haveMissing || showAll) {
            s.append('-----------------------------------------\n');
            if(fileHdl != nil)
                fileHdl.writeFile(s);
            else
                "<<toString(s)>>\b";
        }
        
        // move player back and restore their original values
        gPlayerChar.moveInto(olocn);
        gPlayerChar.isLit = olit;
        return true;
    }

    /*
     *   Helper function to find all rooms in the game
     */
    findAllRooms()
    {
        local rooms = [];
        local currentRoom = firstObj(Room);
        
        while (currentRoom != nil) {
            if (currentRoom.ofKind(Room) && currentRoom.name != nil && currentRoom.name != 'unknown') {
                rooms += currentRoom;
            }
            currentRoom = nextObj(currentRoom, Room);
        }
        return rooms;
    }

    /*
     *   getExitDirs(room)
     *   
     *   Returns a list of directions that are active
     */
    getExitDirs(room)
    {
        local exits = [];
        local exitDirs = [];
        local dest;
        
        // Check each standard direction property
        local dlist = dirs.keysToList();
        local osayflag = captureSayText;
        captureSayText = true;
        foreach (local dirProp in dlist) {
            sayText = '';
            dest = nil;
            try {
                dest = room.(dirProp);
            } catch (Exception ex) {
                continue;
            }
            if (sayText != ' ' || (dest != nil && dataType(dest) == TypeObject &&
                                    (dest.ofKind(Room) || dest.ofKind(TravelConnector)))) {
                exits += dest;
                exitDirs += dirs[dirProp];
            }
        }
        captureSayText = osayflag;      
        return exitDirs;
    }

    
    /*
     *   checkDescrAll()
     *   
     */

    fileHdl = nil
    
    checkDescrAll(showall)
    {
        local allRooms = findAllRooms();    
        local fname = 'checkDescr.txt';
        try {
            fileHdl = File.openTextFile(fname, FileAccessWrite);
        } catch (FileCreationException ex) {
            "### ERROR: Cannot create <<fname>>\b";
            return;
        }
        
        // show progress using dots
        foreach(local rm in allRooms) {
            ".";
            if(!checkDescrRoom(rm,showall))
                break;
        }
        "\n";
        
        try {
            fileHdl.closeFile();
            fileHdl = nil;
        } catch (Exception ex) {
            "### ERROR: Cannot close <<fname>>\b";
            return;
        }
        "Wrote file <<fname>> successfully, analyzing <<allRooms.length()>> rooms.\b";
    }
    
    /*
     *   Lists that user can change
     *   Note that nouns has a special syntax: all lower case, "/" if plural just adds
     *   those extra character(s).  If "/-", then remove last character first.
     *   If the first character is ".", that means the noun is ambiguous in that it could
     *   also be a adverb.  If the first character is a "-", that means this noun should
     *   not need any special additional description (and supercedes the ".").
     *
     *   Nouns are the 500 most popular nouns in the English language according to ChatGPT
     *   run in Oct 2025 removing the ones that are highly likely to be verbs
     *   but also considering this is a description of a room, not the outcome of an
     *   action.
     */
    // also more than just prepositions as our goal is to find nouns
    prepositions = [ 'in', 'into', 'on', 'to', 'onto', 'with', 'under', 'over', 'within',
        'without','that','because','which','where','what','who','while','when',
        'whose', 'above','below','and','be','also','or','either','at','behind', 'against' ]
    // note the articles extended to include ownership as that is a clue to nouns as well
    articles = ['a','an','the','your','my','his','her','its','their']
    // simple set
    directions = ['east','north','west','south','northeast','northwest','southeast',
        'southwest', 'starboard', 'port', 'aft', 'fore', 'down','up']

    // words that immediately drop anything pending
    purgeWords = ['smell','hear','taste','heard','breeze','gust','sound','sight','from']
    // these are even more severe and will drop anything that is happening (noun found)
    hardPurgeWords = ['of','by']

    // adjectives: . if ambiguously adjective or noun
    adjs = [ 
        'very','tall','red','green','blue','orange','white','black','yellow','wet',
        'dark','narrow','wide','deep','shallow','long','short','high','low',
        'steep','rocky','smooth','rough','dry','cold','warm','hot','damp',
        'musty','dusty','ancient','old','new','crumbling','massive','small','tiny',
        'huge','giant','enormous','vast','empty','crowded','silent','echoing','quiet',
        'noisy','bright','dim','faint','glowing','shining','gleaming','golden','.silver',
        'wooden','.stone','.metal','rusty','broken','opened','closed','locked','hidden',
        '.secret','mysterious','strange','familiar','dangerous','.safe','fragile','solid',
        'heavy','thick','thin','clear','cloudy','misty','foggy','smoky','windy',
        'breezy','stale','fresh','sweet','bitter','sharp','blunt','pointed','flat',
        'round','.square','rectangular','triangular','curved','straight','twisted',
        'tangled','polished','jagged','spiky','thorny','bare','leafy',
        'gray','brown','.gold','colorful', '.tree', 'few', '.goat', 'some',
        'pale','dull','shiny','matte','translucent','transparent','opaque',
        'bad','best','better','big','different','early','easy','economic','free','full',
        'good','great','hard','important','international','large','late','little','local',
        '.major','national','political','possible','.public','real','recent','right',
        'social','special','strong','sure','true','whole','young','.american',
        'central','current','difficult','due','entire','final','foreign','.general',
        '.key','legal','likely','main','medical','modern','necessary','nice','personal',
        '.physical','popular','ready','serious','significant','simple','single',
        'traditional','various','western','wrong','common','complete','cultural','dead',
        'democratic','domestic','double','eastern','educational','famous','.fine',
        'former','forward','frequent','.future','historical','.individual','industrial',
        'inner','.junior','leading','left','living','maximum','minimum','minor','northern',
        '.official','opposite','ordinary','.outside','overall','perfect','pleasant','.poor',
        'positive','potential','primary','prime','principal','.private','proper','quick',
        'rapid','rare','regular','.relative','remote','.senior','separate','severe','slow',
        'soft','southern','standard','substantial','sudden','suitable','superior','supreme',
        'temporary','tough','typical','unable','united','universal','upper','urban','useful',
        'usual','visible','visual','.wild','working','.worth','written',
        '.sea','.well'
    ]
    
    // extra (ad)verbs beyond internal actions -- no issues if they collide as existing verb wins
    // these came from the ambiguous nouns below and were determined to best fit here
    extraVerbs = [
        'are','is','am','should','could','might','see','has','had','continues',
        'lives','works','houses','questions','studies','waters','backs','bridges',
        'causes','colors','dances','exchanges','faces','fuels','heats','halves',
        'increases', 'join','joins', 'kill','kills','lack', 'lacks', 'laugh', 'laughs', 
        'lecture','lectures','lifts','misses','mixes','paints','pitches', // 'pools',
        'rains','registers','respects','rests', 'reveals','rides','rises','runs',
        'rushes','sails','saves','scales','searches', 'seasons', 'sell', 'sells','sets',
        'shakes','shifts','shines','shocks','shouts','shows','sinks','sleeps','slips',
        'smokes','sorts','references','repeats','respects','rests','returns','retails',
        'share','shares','stuffs', 'swim', 'swim','tackle','tackles', 'tells',
        'trades','transfers','trues','views','visits','waits', 'warms','washes',
        'wears', 'weathers','wets', 'thinks', 'coming',
        'looking','cloying','though','seldom','around'
    ]
    // - to exclude it, . if ambiguously noun or verb
    // add / to include its plural form; /- is the plural form with last singular char removed
    nouns = [
        '-time/s', 'person/s', '-year/s', '-way/s', '-day/s', 'thing/s', 'man','men',
        'world/s', '-life', 'hand/s', 'part/s', 'child','children', 'eye/s',
        'woman','women', '-place/s', '-work', '-week/s', 'case/s', '.point/s', 'government/s',
        'company/-ies', 'number/s', 'group/s', 'problem/s', '-fact/s', 'beach/es',
        'city/-ies', 'country/-ies', 'family/-ies', 'friend/s', 'house',  'job/s',
        '-month/s', 'mother/s', '-night/s', '-question', 'room/s', 'school/s', '-state/s',
        'story/-ies', 'student/s', '.study', 'system/s', 'water', '-word/s', 'area/s',
        'book/s', 'business/es', 'home/s', '-lot/s', 'money/s', 'people/s', 'corner/s',
        'program/s', 'air', 'animal/s', '-answer/s', 'apple/s', 'art', '.can', 'cans',
        'baby/-ies', '-back', 'ball/s', 'band/s', 'bank/s', 'bar/s', 'base/s', 'basket/s',
        'bath/s', 'battle/s', 'bear/s', 'beauty/-ies', 'bed/s', 'bee/s', 'bell/s', 'belt/s',
        'bench/es', '-benefit/s', 'bicycle/s', 'bird/s', '-birth/s', 'bit/s', 'blade/s',
        'blood', 'boat/s', 'body/-ies', 'bone/s', 'boot/s', '-border/s', 'bottle/s',
        'bowl/s', 'box/es', 'boy/s', 'brain/s', 'branch','.branches', 'bread/s', 'bridge',
        'brother/s', 'brush', '.brushes', 'building/s', 'bulb/s', 'bus/es', 'button/s', 'buyer/s',
        'cake/s', 'camera/s', 'camp/s', '-capital/s', 'car/s', 'card/s', 'carpet/s',
        'cart/s', 'cat/s', '-cause', 'ceiling/s', 'cell/s', 'chain/s', 'chair/s',
        'charger/s', 'chart/s', 'cheese/s', 'chest/s', 'chick/s', 'chicken/s', 'chin/s', 
        'church/es', 'circle/s', 'class/es', 'clock/s', 'cloud/s', 'club','.clubs',
        'coat/s', 'coffee/s', 'collar/s', 'college/s', 'color', '.comb/s',
        '-comedy/-ies', '-comfort/s', '-command/s', 'committee/s', '-competition/s',
        '-complaint/s', 'computer/s', '-condition/s', 'connection/s', '.control/s', '.cook/s',
        'copper/s', '.copy/-ies', 'corn', '-cost/s', 'cotton/s', '-cough/s', '.cover/s',
        'cow/s', '.crack/s', '-credit/s', '-crime/s', 'crop/s', 'cross/es', 'crowd/s', 'cup/s',
        'cupboard/s', 'customer/s', '.cuts', '.cycle/s', 'damage', 'dance', 'danger/s',
        'daughter/s', '-death/s', '-decision/s', '-degree/s', '-design/s', 'desk/s', '-detail/s',
        '-development/s', 'device/s', '-diet/s', '-difference/s', '-difficulty/-ies', '-dinner/s',
        '-direction/s', 'director/s', '-disease/s', 'disk/s', '-distance/s', '-distribution/s',
        'doctor/s', 'dog/s', 'door/s', '-doubt/s', 'drawer/s', 'dress/es', '.driver/s',
        'drug/s', 'ear/s', 'earth/s', '-economy/-ies', 'edge/s', 'doorway/s', 'dome/s',
        '-education/s', '-effect/s', '-effort/s', 'egg/s', '-election/s', 'element/s', 'elevator/s',
        '-emotion/s', 'employee/s', 'employer/s', '-energy/-ies', 'engine/s', 'engineer/s',
        '-entertainment/s', 'environment/s', 'equipment/s', '-error/s', 'event/s', '-example/s',
        '-exchange', '-excitement/s', '-exercise/s', '-experience/s', 'expert/s', '-explanation/s',
        '-face', 'factory/-ies', '-failure/s', 'fan/s', 'farm/s', 'farmer/s',
        'father/s', '-fear/s', 'feature/s', 'fee/s', '-feeling/s', 'female/s', 'field/s',
        '-fight/s', 'figure/s', 'file/s', 'film/s', '-finance/s', 'finger/s',
        '.finish/es', '.fire/s', 'fish/es', 'flight', 'floor/s', 'flower/s',
        '-focus/es', 'food', 'foot','feet', '.force/s', 'forest/s', 'form/s',
        '-fortune/s', 'foundation/s', '.frame/s', '-freedom/s', '.front/s', 'fruit/s',
        'fuel', '-function/s', '-fund/s', 'furniture/s', '-futures', 'game/s',
        'garden/s', 'gas/es', 'gate/s', 'gear/s', 'gene/s', '-generation/s', 'gift/s',
        'girl/s', 'glass/es', '-goal/s', 'god/s', 'grandfather/s', '-here',
        'grandmother/s', 'grass/es', '-growth/s', 'guest/s', '.guide/s',
        'guitar/s', 'gun/s', 'hair/s', '-half', 'hall/s','hallway/s', 'handle/s', 'hat/s',
        'head', '-health/s', 'heart/s', '-heat', '-height/s', 'hell', '-help/s',
        '-history/-ies', 'hole/s', '-holiday/s', 'homework/s', '-hope/s', 'horse/s',
        'hospital/s', 'hotel/s', '-hour/s', 'human/s', 'husband/s', 'ice', '-idea/s',
        'image/s', '-impact/s', '-importance/s', '-impression/s', '-improvement/s',
        '-income/s', '-increase', 'industry/-ies', 'information',
        'initiative','-initiatives', 'injury/-ies', 'insect/s', '-inside/s',
        '-inspection/s', 'inspector/s', 'instance','-instances', 'instructions',
        'insurance', '-interest/s', '-internet/s', '-interview/s', '-introduction/s',
        'investment/s', 'iron/s', 'island/s', 'issue/s', 'item/s', 'jacket/s',
        'joint/s', '-joke/s', 'journey/s', 'judge/s', '-judgment/s', 'juice/s',
        'juniors', 'jury/-ies', 'keys', '-kick/s', 'kid/s', '-kind/s',
        'king/s', 'kitchen/s', 'knee/s', 'knife','knives', '-knowledge/s', 'lab/s',
        'ladder/s', 'lady/-ies', 'lake/s', 'land/s', '-language/s',
        'law/s', 'lawyer/s', 'layer/s', '-lead/s', 'leader/s', '-leadership/s',
        'leaf','leaves', '-league/s', 'leather/s',  'leg/s', '-length/s',
        'lesson/s', 'letter/s', 'level/s', 'library/-ies', 'lift', '.lights',
        '-limit/s', '-line/s', '.link/s', '.list/s', 'literature/s', 'location/s',
        'log/s', '-looks', '-loss/es', '-love/s', '-luck/s', 'lunch/es', 'machine/s',
        'magazine/s', 'mail/s', '-mains', '-maintenance/s', 'male/s',
        'mall/s', '-management/s', 'manager/s', '-manner/s', 'manufacturer/s', 'map/s',
        '-march/es', 'mark/s', 'market/s', '-marketing/s', '-marriage/s', 'material/s',
        '-math/s', 'matter','-matters', 'meal/s', '-meaning/s', '-measurement/s',
        'meat/s', 'media/s', 'medicine/s', '-medium/s', '-meeting/s', 'member/s',
        'membership/s', 'memory/-ies', 'menu/s', 'mess/s', 'message/s', 'metals',
        '-method/s', '-middle/s', '-midnight/s', 'milk/s', '-mind/s', 'mine/s',
        'minister/s', 'minors', '-minute/s', 'mirror/s', '-miss', '-mistake/s',
        '-mix', 'mixture/s', 'mode/s', 'model/s', '-moment/s', 'monitor/s',
        '-mood/s', '-morning/s', 'motor/s', 'mountain/s',
        'mouse','mice', 'mouth/s', '-moves', 'movie/s', 'music/s', 'name/s', 'nation/s',
        'nature', 'neck/s', '-need/s', 'neighbor/s', 'network/s', 'news', 'newspaper/s',
        '-noise/s', 'nose/s', 'note/s', '-nothing', 'notice/s',
        'novel/s', 'nurse/s', 'object/s', '-occasion/s', 'ocean/s',
        'office/s', 'officer/s', 'oil/s', '-operation/s', '-opinion/s',
        '-opportunity/-ies', '-option/s', 'order/s', 'organization/s', 'origin/s',
        '-other','others', '-outcome/s', 'outline/s', 'outsides', 'owner/s', 'page/s',
        '-pain/s', 'paint', '-pair/s', 'paper/s', 'parent/s', 'park/s',
        '-party/-ies', '.pass/es', 'passage/s', 'passenger/s', '-past/s', 'path/s',
        'patient/s', 'pattern/s', '-payment/s', '-peace/s', 'pen/s', 'pencil/s',
        '-percent/s', '-performance/s', '-period/s', '-permission/s',
        'pet/s', 'phone/s', 'photo/s', 'picture/s', 'piece/s', 'pig/s',
        'pilot/s', 'pipe/s', 'pitch', 'plan/s', 'plane/s',
        'planet/s', 'plant/s', 'plastic/s', 'plate/s', '.play/s', 'player/s', 'pocket/s',
        'poem/s', 'poet/s', 'police', '-policy/-ies', '-politics/s',
        '-pollution/s', 'pool', 'population/s', 'ports', 'position/s',
        '-possibility/-ies', 'post/s', 'pot/s', 'potato/s', 'pound/s', '-power/s',
        '-practice/s', 'president/s', '-pressure/s', '-price/s', '-pride/s', 'priest/s',
        'prince/s', 'princess/es', '-principle/s', 'print/s', 'prison/s', 'prisoner/s',
        'prize/s', 'process/es', 'product/s', '-production/s',
        '-profession/s', 'professor/s', '-profit/s', 'project/s',
        '-promise/s', '-proof/s', 'property/-ies', '-protection/s', '-psychology/-ies',
        'publisher/s', '-purpose/s', '-pushes', '-quality/-ies',
        '-quarter/s', 'queen/s', 'race/s', 'radio/s', 'rail/s', 'rain',
        '.range/s', '-rate/s', '-ratio/s', '-raw', '-reaction/s', 'reader/s',
        '-reading/s', '-reality/-ies', '-reason/s', 'receipt/s', 'reception/s',
        'recipe/s', 'record/s', '-recovery/-ies', 'reference',
        'reflection/s', 'refrigerator/s', '-refusal/s', 'region/s', 'register',
        '-regret/s', 'regulation/s', '-relation/s', '-relationship/s', 'relatives',
        '-religion/s', '-remainder/s', '-removal/s', '-rent/s', 'repair/s', '-repeat',
        'replacement/s', '-reply/-ies', 'report/s', 'representative/s', '-reputation/s',
        '-request/s', 'requirement/s', '-rescue/s', '.research', 'reserve/s',
        'resident/s', '-resistance/s', '-resolution','resolutions', 'resource/s',
        '-respect', '-response/s', '-responsibility/-ies', '-rest', 'restaurant/s',
        '-result/s', '-retail', '-return', '-reveal', '-revenue/s', '-review/s',
        '-revolution/s', 'reward/s', 'rice/s', '-rich/es', '-ride', '-rights',
        'ring/s', '-rise', 'risk/s', 'river/s', 'road/s', 'robot/s', 'rock/s',
        '-role/s', 'roll/s', 'roof/s', 'root/s', 'rope/s', 'rose/s', 'rounds',
        'route/s', '-routine/s', '.row/s', 'rubber','-rubbers', 'rule/s', '-run',
        '-rush/s', '-sad', 'safes', '-safety/-ies', 'sail', '-sake/s', 'salad/s',
        '-salary/-ies', '-sale/s', 'salt/s', '-same', 'sample/s', 'sand/s', 'sandwich/es',
        '-satisfaction/s', 'sauce/s', '-save', '-saving','savings', 'scale',
        '-scene/s', 'schedule','-schedules', '-scheme/s', 'science/s',
        'scientist/s', 'scope/s', 'score/s', 'screen/s', 'script/s', 'seas',
        '-season', 'seat/s', '-second/s', 'secrets', 'secretary/-ies',
        'section/s', 'sector/s', 'security/-ies', 'seed/s', 'selection/s',
        'self','-selves', 'seniors', '-sense/s', '-sentence/s', '-series/s',
        '-service/s', '-session/s',  'setting/s', 'settlement/s', '-sex/es',
        '-shade/s', '-shadow/s', '.shake', '-shame/s', 'shape/s',  'shark/s',
        'sheet/s', 'shelf','shelves', 'shell/s', 'shelter/s', '-shift',
        '-shine', 'ship/s', 'shirt/s', '-shock', 'shoe/s', '-shoot/s', 'shop/s',
        'shore/s','shorts', '-shot/s', 'shoulder/s', '-shout',
        '-side/s', 'sight/s', 'sign/s', 'signal/s', '-silence/s', 'silk',
        '-sin/s', 'singer/s', 'sink', '-sir/s', 'sister/s',
        'site/s', '-situation/s', '-size/s', '-skill/s', 'skin','-skins', 'skirt/s',
        'sky/-ies', 'slave/s',  '.slice','-slices', '.slide/s', '-slip',
        '-smells', '-smile/s', 'smoke/r', 'snake/s', 'snow','-snows', 'soap/s',
        '-society/-ies', 'sock/s', 'soil/s', 'soldier/s', '-solids',
        'solution','-solutions', 'son/s', 'song/s', '-sort', 'soul/s', '-sounds',
        'soup/s', 'source/s', 'space/s', '-spare/s', 'speaker/s',
        '-speech/es', '-speed/s', 'spell/s', '-spend/s', 'spirit/s',
        '-spite/s', '-sport/s', 'spot/s', '-spread/s', 'spring','-springs', 'squares',
        'staff/s', 'stage/s', 'stain/s', 'stair/s', 'stake/s', 'stamp/s', '-stands',
        'star/s', '-start/s', 'station/s', '-stay/s', 'steak/s',
        '-steal/s', 'steam','-steams', 'steel', '-step/s', 'stick/s', '-still/s',
        '-stock/s', 'stomach/s', 'stones', '.stop/s', 'store/s', 'storm/s',
        'stove/s', 'strait', 'stranger/s', 'straw/s',
        'stream','.streams', 'street/s', '-strength/s', '-stress/es', '-stretch/es',
        '-strikes', 'string/s', '.strip/s', '-stroke/s', 'structure/s',
        '-struggle/s', '.stuff', '-style/s',
        '-subject/s', 'substance/s', '-success/s', 'sugar/s', 'suit/s', 'summer/s',
        'sun/s', 'supermarket/s', 'supply/-ies', '-support/s', 'surface/s', '-surprise/s',
        '-surrounding','surroundings', 'survey/s', '-survival/s', 'survivor/s',
        '-suspicion/s', 'sweater/s', 'sweets', '.swing/s', '.switches',
        'symbol/s', '-sympathy/-ies', 'table/s',  'tail','.tails',
        'tale/s', 'tank/s', '.tap/s', '.tape/s', 'target/s', '-task/s', '-tastes',
        '-tax/es', 'tea/s', 'teacher/s', 'team/s', 'tear/s', 'technology/-ies',
        'teenager/s', 'telephone/s', 'television/s', '-temperature/s',
        'temple/s', '-tendency/-ies', '-tennis', '-tension/s', 'tent/s', '-term/s',
        'territory/-ies', 'tests', 'text/s', '-thank/s', 'theater/s', 'theme/s',
        'theory/-ies', '-therapy/-ies', '-there', 
        '-third/s', '-thought/s', 'thread/s', 'threat/s', 'throat/s',
        '-through/s', 'thumb/s', 'ticket/s', 'tie/s', '-tight/s', '-till/s',
        '.tip/s', 'tire/s', 'tissue/s', '-title/s', 'toast','-toasts', '-today', 'toe/s',
        '-together/s', 'toilet/s', 'tomato/es', '-tomorrow', '-tone/s', 'tongue/s',
        '-tonight/s', 'tool/s', 'tooth','teeth', 'top/s', 'topic/s', '-total/s',
         '-tour/s', 'tourist/s', '-toward/s', 'towel/s', 'tower/s', 'town/s', 'toy/s',
        '.trade','track/s', '-tradition/s', 'traffic/s', 'train/s', '-training/s',
        '-transfer', 'transport/s', '.trap/s', '-travel/s', 'tray/s', 'treasure/s',
        'treatment/s', 'trees', 'trial/s', 'tribe/s', '.trick/s', '-trip/s', 'trouble/s',
        'truck/s', '.trust/s', '-truth/s', '-try/-ies', 'tube/s', 'tune/s',
        '-turns', 'twist/s', '-types', 'uncle/s', '-understanding/s',
        '-union/s', 'unit','-units', 'university/-ies', 'upstairs',
        'user/s', 'vacation/s', 'valley/-ies', 'value/s', 'variety/-ies',
        'vegetable/s', 'vehicle/s', 'version/s', 'vessel/s', 'victim/s', 'video/s',
        'view', 'village/s', '-violence/s', 'virus/s', '-visit', 'visitor/s',
        'voice/s', '-volume/s', '-vote/s', '-wage/s', '-wake/s',
        '-walk/s','walkway','wall/s', 'war/s', 'warning/s', 'wash',
        'waste/s', '.watch/es', '.wave/s', '-weak/s', '-wealth',
        'weapon/s', 'weather', 'web/s', '-wedding/s',
        '-weekend/s', '-weight','weights', '-welcome/s', 'wells',
        'wheel/s', '-whom', '-why/s', 'wife','wives', 'wilds', '.will','-wills',
        '-win/s', 'wind/s', 'window/s', 'wine/s', 'wing/s', 'winner/s', '-winter/s',
        'wire/s', '-wise', '-wish/es',
        '-wonder/s', 'wood/s', 'wool', 'worker/s',
        '-worry/-ies', '-would', 'writer/s', 'writing/s',
        'yard/s', '-yes/es', '-yesterday/s', '-yet',
        '-yours', 'youth/s', 'zone/s',
        
        // from another pass
        'cave/s','chamber/s','entrance/s','tunnel/s','boulder/s','stalactite/s','stalagmite/s',
        'archway/s','corridor/s','pit/s','ledge/s','slope/s','cliff/s',
        'crevice/s', 'opening/s','alcove','niche','echo','dust',
        'hill/s','plain/s','meadow/s','grove/s',
        'trail/s','platform/s','column/s','pillar/s','statue/s','altar/s',
        'crate/s','barrel/s','painting/s','carving/s','inscription/s',
        'portal/s','curtain/s','crystal/s','gem/s','jewel/s',
        'coin/s','artifact/s','scroll/s','torch/es','lantern/s','lamp/s','candle/s',
        'flame/s','ember/s','mist/s','fog',
        '-whisper/s','footstep/s','bat/s','rat/s','spider/s',
        'frog/s','monster/s','ghost/s','skeleton/s','corpse/s','skull/s',
        'guard/s','wizard/s',
        'servant/s','merchant/s','traveler/s','adventurer/s',
        'warlock/s','witch/es',
        'attic','balcony','barn','bay','bedroom/s','boathouse','boulevard',
        'burrow','cabinet/s','cabin/s','castle/s','catacomb','cellar','chasm/s',
        'clearing','closet/s','coast','compound/s','conservatory','courtyard','den','dock/s',
        'dormitory','dune','dwelling','enclosure','estate/s','foyer','gallery',
        'gatehouse','gazebo','grottos','harbor','hearth','hut/s',
        'laboratory','landing/s','lobby','loft','manor/s',
        'mansion/s','moat','nursery','observatory/-ies','orchard/s','outhouse/s',
        'overlook/s','pantry/-ies',
        'parlor/s','passageway','piazza','plaza','porch','quarry','ramp','refuge',
        'reservoir','ridge','roadway','ruin','saloon','sanctuary','shed','shrine',
        'stable/s','stall','storeroom/s','studio','suite/s','summit','swamp',
        'terrace/s','turf','vault/s','veranda','villa','warehouse/s','workshop/s',
        
        // more nouns
        'goats','riverbank/s',
        
        // the list of nouns that cannot be used
        '-xxxx'
    ]
;

/*
 *   Commands to look at a room
 */

VerbRule(CheckDescrAll)
    'checkAllRoomDescr' (|'-showall' -> showall)
    : VerbProduction
    action = CheckDescrAll
    verbPhrase = 'checkAllRoomDescr'
;

DefineSystemAction(CheckDescrAll)
    execAction(cmd) {
        local showall = cmd.verbProd.showall;
        checkDescrObj.checkDescrAll(showall);
    }
;

VerbRule(CheckDescr)
    'checkRoomDescr' singleDobj
    : VerbProduction
    action = CheckDescr
    verbPhrase = 'checkRoomDescr (room)'
    missingQ = 'which room do you want to check'
    dobjReply = singleNoun
;


DefineTAction(CheckDescr)   
    
    /* The CheckDescr action requires universal scope */
    addExtraScopeItems(whichRole?)
    {
        makeScopeUniversal();
    }  
    beforeAction() { }
    afterAction() { }
    turnSequence() { }
;

modify Thing
    /* 
     *   The GoNear action allows the player character to teleport around the
     *   map.
     */
    dobjFor(CheckDescr)
    {       
        verify()
        {
            if(getOutermostRoom == nil)
                illogicalNow('Cannot find the room. ');
            
            if(ofKind(Room))
                logicalRank(120);
        }
        
        action()
        {
            checkDescrObj.fileHdl = nil;
            checkDescrObj.checkDescrRoom(gDobj,true);            
        }
    }
    
    // just to make analysis quicker
    isIlluminated() {
        if(checkDescrObj.captureSayText)
            return true;
        else
            return inherited();
    }

;

modify Room
    // just to make analysis quicker
    litWithin() {
        if(checkDescrObj.captureSayText)
            return true;
        else
            return inherited();
    }
;

/*
 *   Have to mess with some of the code in order to collect the information we need to
 *   process things
 */

modify aioSay(txt)
{
    if(checkDescrObj.captureSayText)
        checkDescrObj.addSayText(txt);
    else
        replaced(txt);
}
;

modify Action
{
    turnSequence() {
        if(!checkDescrObj.captureSayText)
            inherited();
    }
}
;

// just in case we somehow end up here -- do not want it to actually end the game
modify finishGameMsg(msg,extra)
{
    if(!checkDescrObj.captureSayText)
        replaced(msg,extra);
}
;

#endif
