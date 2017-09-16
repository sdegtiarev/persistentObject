module std.experimental.perышыеуте;

private import std.traits : hasIndirections, isAssignable;
private import std.exception;
private import std.string;
private import std.conv;
private import std.format : FormatSpec, formatValue;
private import core.stdc.stdio;
version (Windows)
{
private import core.sys.windows.windows;
private import std.utf;
private import std.windows.syserror;
}
else version (Posix)
{
private import core.sys.posix.fcntl;
private import core.sys.posix.unistd;
private import core.sys.posix.sys.mman;
private import core.sys.posix.sys.stat;
}
else
{
static assert(0);
}

/**
 * Creates an object mapped to a file. The object is persistent 
 *   and outlives the parent application. The file may be reopened
 *   and the object reused, it's value persists. This might be viewed
 *   as kind of binary serialization with the difference that access
 *   to the variable is almost as fast as any regular memory. The 
 *   structure might be also used as memory shared between processes/threads,
 *   however, no built-in synchronization is provided.
 *
 * If the template parameter T is immutable, the created object is also
 *   immutable. Note: shared memory is then created in read-only
 *   mode, so even cast to mutable and attempt to modify it will cause
 *   segmentation fault.
 *
 * The Persistent(T) exists in two forms. When T is regular value type
 *   (including static arrays), Persistent(T) behaves like reference to
 *   the object. In the second form, Persistent(T[]), the class behaves
 *   as proxy to dynamic array providing slicing interface. Note, even
 *   in this case, elements of the array must be value type, no pointers
 *   nor references to process's memory allowed.
 *
 * The values created are initialized with std.conv.emplace using
 *  additional arguments if any. The object remains in valid state
 *  until the file is deleted or modified.
 **/
struct Persistent(T)
{
    // underlying shared memory allocator
    private ShMem _heap;
    private enum _tag="Persistent!("~T.stringof~")";

    //dynamic array
    static if(is(T == Element[],Element))
    {
        private Element[] _value;
        private enum bool dynamic=true;
        static assert(!hasIndirections!Element
            , Element.stringof~" is reference type");

        /** Proxy to underlying dynamic array type.
         *  Forwards calls to opSlice(), length() etc
         */
        @property Element[] Ref() { return _value; }

        /// Convert to string the value, not the class itself
    	@property void toString(scope void delegate(const(char)[]) sink,
            FormatSpec!char fmt) const
        {
	        sink.formatValue(_value, fmt);
        }

        /// Index of uninitialized part of the array
        @property initIndex() const { return _heap.unplowed/Element.sizeof; }
    }
    // scalar value or static array
    else
    {
        alias Element=T;
        private Element* _value;
        private enum bool dynamic=false;
        static assert(!hasIndirections!T
            , T.stringof~" is reference type");

        /** Reference to underlying scalar value
         */
        @property ref Element Ref() {    return *_value; }

        /// Convert to string
    	@property void toString(scope void delegate(const(char)[]) sink,
            FormatSpec!char fmt) const
        {
	        sink.formatValue(*_value, fmt);
        }
    }

    /** If whole or part of the file was created and 
     *  was initialized in constructor, return true. 
     *    For scalar types this means, the entire object was constructed.
     *  For dynamic arrays initIndex() shows first initialized
     *  elsement.
     */
    @property master() const { return _heap.master; }

    static if(isAssignable!Element)
        enum mode=ShMem.Mode.readWrite;
    else
        enum mode=ShMem.Mode.readOnly;

/**
 * Universal constructor, for both scalar and array types.
 * Opens file and assosiates object with it.
 * The file is extended if required.
 * The object is initialized if file was created or extended.
 */
    this(Arg...)(string path, Arg arg)
    {
        // dynamic array
        static if(dynamic)
        {
            _heap=shMem(path, mode);
            enforce(_heap.length >= Element.sizeof, _tag~": file is too small");
            _value=cast(Element[]) _heap[0.._heap.length];
            // initialization
            static if(isAssignable!Element)
            {
                if(master)
                    foreach(i, ref x; _value[initIndex..$])
                        emplace(&x, arg);
            }
            else
            {
                static assert(arg.length == 0
                    , _tag~": attempt to initialize immutable memory");
            }
        }
        // scalar value
        else
        {
            _heap=shMem(path, Element.sizeof, mode);
            enforce(_heap.length >= Element.sizeof, _tag~": file is too small");
            _value=cast(Element*) _heap[].ptr;

            // initialization
            static if(isAssignable!Element)
            {
                if(master)
                    emplace(_value, arg);
            }
            else
            {
                static assert(arg.length == 0
                    , _tag~": attempt to initialize immutable object");
            }
        }
    }

/**
 * Open file and map dynamic array to it.
 * Creates array of requested length, file is extended if necessary
 */
    this(Arg...)(size_t len, string path, Arg arg)
    if(dynamic)
    {
        immutable size_t size=len*Element.sizeof;
        
        _heap=shMem(path, size, mode);
        _value=cast(Element[]) _heap[0..size];
        // initialization
        static if(isAssignable!Element)
        {
            if(master)
                foreach(ref x; _value[initIndex..$])
                    emplace(&x, arg);
        }
        else
        {
            static assert(arg.length == 0
                , _tag~": attempt to initialize immutable array");
        }
    }
     

 // get reference to wrapped object.
    alias Ref this;

}


///
unittest
{
    import std.stdio;
    import std.file : remove, exists, deleteme;

    // custom data examples
    struct A { int x; };
    class B {};
    enum Color { black, red, green, blue, white };

    string[] file;
    foreach(i; 0..8) file~=deleteme~to!string(i);
    scope(exit) foreach(f; file[]) if(exists(f)) remove(f);

    /// Part 1: create mapped variables
    {
        // simle int variable initialized with default value
        auto p0=Persistent!int(file[0]);
        assert(p0 == int.init);
        p0=7;
        assert(p0 == 7);

        // single double value initialized in ctor
        // , would throw if the file did exist.
        auto p1=Persistent!double(file[1], 2.71828);
        assert(p1 == 2.71828);
        p1=3.14159;

        // struct, initialized in ctor
        auto p2=Persistent!A(file[2], 22);
        assert(p2.x == 22);
       
        // static array of integers, assignable
        auto p3=Persistent!(int[5])(file[3]);
        assert(p3[0] == int.init);
        p3=[1,3,5,7,9];
        assert(p3[0] == 1);

        // enum, initialized in ctor
        auto p4=Persistent!Color(file[4], Color.red);
        assert(p4 == Color.red);
        

        // character string
        auto p5=Persistent!(char[32])(file[5]);
        p5="hello world";

        // second order static array
        auto p8=Persistent!(char[3][5])(file[6]);
        p8[]="..."; p8[1]="one"; p8[2]="two";


        /// Compile time errors
        // char* is reference type
        static assert(!is(typeof(Persistent!(char*)("?"))));
        // B is class, reference type
        static assert(!is(typeof(Persistent!(B)("?"))));
        // char* is reference type
        static assert(!is(typeof(Persistent!(char*)("?"))));
        // char*[12] is reference type
        static assert(!is(typeof(Persistent!(char*[12])("?"))));
        // char[string] is reference type
        static assert(!is(typeof(Persistent!(char[string])("?"))));
        // char[] is reference type
        static assert(!is(typeof(Persistent!(char[][])("?"))));
        // char[][3] is reference type
        static assert(!is(typeof(Persistent!(char[][3])("?"))));
    }
    /// destroy everything and unmap files
    

    
    /// Part 2: map again and check the values are preserved
    {
        // Was previosly mapped as int and assigned 7
        auto p0=Persistent!int(file[0]);
        assert(p0 == 7);
        // int cannot be emplaced from a double
        static assert(!is(typeof(Persistent!int("?", 1.0))));
        /// attempt to initialize immutable array
        static assert(!is(typeof(Persistent!(immutable(int)[])(3,file[0],34))));
        /// The file was only 4 bytes long
        ///   , immutable storage can't be extended
        assertThrown(Persistent!(immutable(int)[])(3,file[0]));
    
        /// This works, extend the storage and 
        ///  init appended tail, but not existing part
        auto p1=Persistent!(int[])(3,file[0],123);
        assert(p1[0] == 7);
        assert(p1[1] == 123);
        assert(p1.length == 3);

        // Was previousli mapped as double and assigned 3.14159
        auto p2=Persistent!double(file[1]);
        assert(p2 == 3.14159);

        // struct with int member initialized with 22
        auto p3=Persistent!A(file[2]);
        assert(p3 == A(22));
        
        // Was mapped as int[5], remap as view only array of shorts
        auto p4=Persistent!(immutable(short[]))(file[3]);
        assert(p4.length == 10);
        // Assuming LSB
        assert(p4[0] == 1 && p4[2] == 3 && p4[4] == 5);
        // cannot modify immutable expression
        static assert(!is(typeof(p4[1]=111)));
 
        // enum, was set to Color.red
        auto p5=Persistent!Color(file[4]);
        assert(p5 == Color.red);

        // view only variant of char[4]
        auto p6=Persistent!string(4, file[5]);
        assert(p6 == "hell");
        // cannot modify immutable expression
        static assert(!is(typeof(p6[0]='A')));
        // slice is not mutable
        static assert(!is(typeof(p6[]="1234")));

        // remap second order array as plain array
        auto p7=Persistent!(const(char[]))(file[6]);
        assert(p7.length == 15);
        assert(p7[0..5] == "...on");
        // map again as dynamic array
        auto p8=Persistent!(char[3][])(file[6]);
        assert(p8.length == 5);
        assert(p8[2] == "two");
        // Array lengths don't match for copy: 4 != 3
        //p8[0]="null";

        // write-protected file
        { File(file[7],"w").write("12345678"); }
        chmod(file[7].toStringz, octal!444);
        // mutable array can't be mapped on read-only file 
        assertThrown(Persistent!(int[])(file[7]));
        // immutable array can be mapped
        auto p9=Persistent!(immutable(int)[])(file[7]);
        assert(p9.length == 2);

    }

}




package class ShMem
{
    enum Mode
    {
          readOnly        /// Read existing file
        , readWrite       /// Read/Write, create if not existing
        , noExpand        /// Read/Write existing file, do not increaze file size
    }





    this(string path, size_t len, Mode mode =Mode.readWrite)
    {
        fileOpen(path, mode);
        scope(failure) { close(_fd); _fd=-1; }

        auto size=fileSize(path);
        if(size < len)
        {
            enforce(writeable && mode != Mode.noExpand, path~": file is too short");
            _index=size;
            _master=true;
            size=fileExpand(path, len);
        }
        else
        {
            _index=len;
        }

        map(path, len);
    }


    this(string path, Mode mode =Mode.readWrite)
    {
	    version(Posix)
	    {
		    scope(failure) { close(_fd); _fd=-1; }
	    }
	    version(Windows)
	    {
            scope(failure) {
            	if(hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile);
            }
	    }
        fileOpen(path, mode);

        auto len=fileSize(path);
        enforce(len > 0, path~": zero size file");
        _index=len;
        _master=false;

        map(path, len);
    }


    ~this()
    {
        if(_fd >= 0)
        {
            unmap();
            fileClose();
        }
    }


    void[] opSlice()
    {
        return _data[0..$];
    }

    void[] opSlice(size_t i, size_t k)
    {
        return _data[i..k];
    }

    void opIndex(size_t i)
    {
        return _data[i];
    }

    @property auto length() const { return _data.length; }

    @property bool writeable() const { return _writeable; }

    @property bool master() const { return _master; }

    @property auto unplowed() const { return _index; }

    






    version(Posix)
    {
        private int _fd;
    }
    version(Windows)
    {
        HANDLE hFile=INVALID_HANDLE_VALUE;
        HANDLE hFileMap=null;
    }
    private void[] _data;
    private bool _writeable;
    private bool _master;
    private size_t _index;
    

    private void fileOpen(string path, Mode mode)
    {
        version(Posix)
        {
            /// in read-only mode, the file must exist
            if(mode == Mode.readOnly)
            {
                _fd=core.sys.posix.fcntl.open(toStringz(path), O_RDONLY);
                errnoEnforce(_fd >= 0, path);
                _master=false;
                _writeable=false;
                return;
            }

            /// try to create the file
            _fd=.open(toStringz(path), O_RDWR|O_CREAT|O_EXCL, S_IRUSR|S_IWUSR);
            if(_fd >= 0)
            {
                _master=true;
                _writeable=true;
                return;
            }

            /// otherwise, try to open read/write existing file
            _fd=.open(toStringz(path), O_RDWR, S_IRUSR|S_IWUSR);
            if(_fd >= 0)
            {
                _master=false;
                _writeable=true;
                return;
            }

            errnoEnforce(false, path);
  
        }
        else version(Windows)
        {
            /// in read-only mode, the file must exist
            if(mode == Mode.readOnly)
            {
                hFile=CreateFileW(filename.tempCStringW()
                	, GENERIC_READ
                	, FILE_SHARE_READ
                	, null
                    , OPEN_EXISTING
                    , FILE_ATTRIBUTE_NORMAL
                    , cast(HANDLE)null);
                if(hFile != INVALID_HANDLE_VALUE)
                {
                	_master=false;
                	_writeable=false;
             		return;
             	}
 
            }

            /// try to create the file
            hFile=CreateFileW(filename.tempCStringW()
            	, GENERIC_READ | GENERIC_WRITE
            	, FILE_SHARE_READ | FILE_SHARE_WRITE
            	, null
                , CREATE_ALWAYS
                , FILE_ATTRIBUTE_NORMAL
                , cast(HANDLE)null);
            if(hFile != INVALID_HANDLE_VALUE)
            {
                _master=true;
                _writeable=true;
           	    return;
           	}

            /// otherwise, try to open read/write existing file
            return;
            hFile=CreateFileW(filename.tempCStringW()
            	, GENERIC_READ | GENERIC_WRITE
            	, FILE_SHARE_READ | FILE_SHARE_WRITE
            	, null
                , OPEN_EXISTING
                , FILE_ATTRIBUTE_NORMAL
                , cast(HANDLE)null);
            if(hFile != INVALID_HANDLE_VALUE)
            {
                _master=false;
                _writeable=true;
           	    return;
           	}

            wenforce(false, path);
        }

    }


    
    private void fileClose()
    {
        version(Posix)
        {
	        close(_fd);
	        _fd=-1;
        }
        else version(Windows)
        {
			CloseHandle(hFile);
			hFile=INVALID_HANDLE_VALUE;
        }
    }


    
    private size_t fileSize(string path)
    {
        version(Posix)
        {
            stat_t st;
            errnoEnforce(!.stat(toStringz(path), &st), path);
            return st.st_size;
        }
        else version(Windows)
        {
            uint size1=0, size2=GetFileSize(hFile, &size1);
            wenforce(size2 != INVALID_FILE_SIZE || GetLastError() == ERROR_SUCCESS, path);
            return (cast(ulong)size1<<32)+size2;
        }
    }



    private size_t fileExpand(string path, size_t len)
    {
        version(Posix)
        {
            errnoEnforce(lseek(_fd, len-1, SEEK_SET) == (len-1), path);
            char c=0;
            errnoEnforce(core.sys.posix.unistd.write(_fd, &c, 1) == 1, path);

        }
        else version(Windows)
        {
        }
        
        return fileSize(path);
    }



    private void map(string path, size_t size)
    {
        version(Posix)
        {
            void* heap=MAP_FAILED;
            if(writeable)
                heap=mmap(null, size, PROT_READ|PROT_WRITE, MAP_SHARED, _fd, 0);
            else
                heap=mmap(null, size, PROT_READ, MAP_SHARED, _fd, 0);
            errnoEnforce(heap != MAP_FAILED, path~" : "~to!string(size));
            _data=heap[0..size];

        }
        else version(Windows)
        {
			void* heap=MAP_FAILED;
			if(writeable)
				heap=MapViewOfFileEx(hFileMap, FILE_MAP_WRITE, 0, 0, size, null);
			else
				heap=MapViewOfFileEx(hFileMap, FILE_MAP_READ, 0, 0, size, null);
            wenforce(heap, path);
            _data=heap[0..size];
        }
    }



    private void unmap()
    {
        version(Posix)
        {
            munmap(_data.ptr, _data.length);
        }
        else version(Windows)
        {
	        wenforce(UnmapViewOfFile(_data.ptr) != FALSE, "UnmapViewOfFile");
	        CloseHandle(hFileMap);
        }
    }

}



/// class factory function
ShMem shMem(string path, size_t len, ShMem.Mode mode=ShMem.Mode.readWrite)
{
    return new ShMem(path, len, mode);
}


/// class factory function
ShMem shMem(string path, ShMem.Mode mode=ShMem.Mode.readWrite)
{
    return new ShMem(path, mode);
}





/// Using of package scoped shared memory allocator
unittest
{
    import std.file : remove, deleteme;
    

    string file=deleteme~"1";
    scope(exit) remove(file);

    
    {
        auto s1=shMem(file, 8);
        enforce(s1.master);
        enforce(s1.writeable);
        enforce(s1.unplowed == 0);
        enforce(s1.length == 8);

        int[] i=cast(int[]) s1[];
        enforce(i.length == 2);
        i[0]=12;
        i[1]=13;
    }
    {
        auto s2=shMem(file, 12);
        enforce(s2.master);
        enforce(s2.writeable);
        enforce(s2.unplowed == 8);
        enforce(s2.length == 12);

        int[] i=cast(int[]) s2[];
        enforce(i.length == 3);
        enforce(i[0] == 12);
        enforce(i[1] == 13);
    }
    {
        auto s3=shMem(file, 4, ShMem.Mode.readOnly);
        enforce(!s3.master);
        enforce(!s3.writeable);
        enforce(s3.unplowed == 4);
        enforce(s3.length == 4);

        int[] i=cast(int[]) s3[];
        enforce(i.length == 1);
        enforce(i[0] == 12);
    }
    {
        auto s4=shMem(file);
        enforce(!s4.master);
        enforce(s4.writeable);
        enforce(s4.unplowed == 12);
        enforce(s4.length == 12);
    }
    {
        assertThrown(shMem(file, 24, ShMem.Mode.readOnly));
    }
    {
        chmod(toStringz(file), octal!444);
        assertThrown(shMem(file, 24));
    }


}

