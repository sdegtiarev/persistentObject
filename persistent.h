#ifndef _ITC_PERSISTENT_H
#define _ITC_PERSISTENT_H
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <tuple>
#include "tmx/sysutil.h"
using namespace tmx;
namespace persistent {

// verify the file is of sufficient size and expand
// return original file size
inline size_t resize(int fd, size_t n =0)
{
	auto off=::lseek(fd, 0, SEEK_END);
	if(off < 0)
		throw tmx::syserr("persistent::resize");
	// 
	if(n == 0) {
		n=off;
	} else if(off < n) {
		char *buf=new char[n-off];
		if(::write(fd, buf, n-off) < 0)
			throw tmx::syserr("persistent::resize");
	}
	
	::lseek(fd, 0, SEEK_SET);
	return std::min(static_cast<size_t>(off),n);
}






// open file for mapping
inline std::pair<int,size_t> open(const std::string& file, size_t n =0)
{
	auto fd=n? ::open(file.c_str(), O_RDWR|O_CREAT|O_EXCL, S_IRUSR|S_IWUSR) : -1;
	if(fd < 0) {
	// file exists (O_EXCL)
		fd=::open(file.c_str(), O_RDWR, S_IRUSR|S_IWUSR);
		enforce(fd >= 0, syserr("persistent: %s", file));
	}

	return std::make_pair(fd, resize(fd, n));
}


// mmap the file
inline char* mmap(size_t n, int fd)
{
	auto m=::mmap(0, n, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
	if(!m)
		throw syserr("mmap");
	return static_cast<char*>(m);
}



// static version of persistent object, memory size is known at compile time
template<int SIZE>
class memory
{
public:
	memory(const std::string& file) try {
		fd_guard fd;
		std::tie(fd,_init)=open(file, SIZE);
		_map=mmap(SIZE, fd);
	} catch(std::exception const& x) { throw error(file)<<": "<<x.what(); }
	memory(const memory&) =delete;
	memory(memory&& m)
	: _map{nullptr}
	, _init{0}
	{
		std::swap(_map, m._map);
		std::swap(_init, m._init);
	}
	
	~memory() {
		if(_map) { ::munmap(_map, SIZE); }
	}
	// return initialized (pre-existing) portion of the memory
	size_t initialized() const { return _init; }
	
protected:
	char* map() { return _map; }
private:
	char  *_map;
	size_t _init;
};





// dynamic version of persistent object, memory size is passed as parameter
class alloc
{
public:
	alloc(size_t n, const std::string& file)
	: _size(n)
	{
	try {
		fd_guard fd;
		std::tie(fd,_init)=open(file, _size);
		_map=mmap(_size, fd);
	} catch(std::exception const& x) { throw error(file)<<": "<<x.what(); }
	}
	alloc(const std::string& file)
	{
	try {
		fd_guard fd;
		std::tie(fd,_size)=open(file, 0);
		_map=mmap(_size, fd);
		_init=_size;
	} catch(std::exception const& x) { throw error(file)<<": "<<x.what(); }
	}

	alloc(alloc const&) =delete;
	alloc(alloc&& m)
	: _map{nullptr}
	, _init{0}
	, _size{0}
	{
		std::swap(_map, m._map);
		std::swap(_init, m._init);
		std::swap(_size, m._size);
	}
	alloc& operator=(alloc const&) =delete;
	alloc& operator=(alloc&& m)
	{
		if(&m != this) {
			std::swap(_map, m._map);
			std::swap(_init, m._init);
			std::swap(_size, m._size);
		}
		return *this;
	}
	
	~alloc() {
		if(_map) { ::munmap(_map, _size); }
	}
	size_t initialized() const { return _init; }
	
protected:
	char* map() { return _map; }
	unsigned size() const { return _size; }
private:
	char  *_map;
	size_t _init, _size;
};






template<class T>
class object : public memory<sizeof(T)>
{
	T *_po;
	typedef memory<sizeof(T)> base;

public:
	object(const object<T>&) =delete;
	object(object<T>&&)      =default;
	~object() {
		//do not destroy the object
		// NO NO NO _po->~T();
	}
	

	// smart ptr semantics
	T* operator->() { return _po; }
	T& operator*() { return *_po; }
	const T* operator->() const { return _po; }
	const T& operator*() const { return *_po; }
	

	//////// parameters forwarded
	template<typename ...Args>
	object(const std::string& file, Args...args)
	: memory<sizeof(T)>(file)
	, _po{reinterpret_cast<T*>(base::map())}
	{
		if(base::initialized() < sizeof(T))
			new(_po) T(args...);
	}

};



template<class T>
class array : public alloc
{
	size_t _size;
	T *_po;

public:
	array(const array<T>&) =delete;
	array(array<T>&&) =default;
	array& operator=(const array<T>&) =delete;
	array& operator=(array<T>&&) =default;
	~array() {
		//do not destroy the object
	}
	size_t size() const { return _size; }
	size_t length() const { return size(); }
	

	// smart ptr semantics
	T& operator[](size_t n) {
		if(n >= _size)
			throw error("persistent: overlimit: ")<<n<<" >= "<<_size;
		return _po[n];
	}
	T const& operator[](size_t n) const {
		if(n >= _size)
			throw error("persistent: overlimit: ")<<n<<" >= "<<_size;
		return _po[n];
	}

	// iterator semantics
	T* begin() { return _po; }
	T* end() { return _po+_size; }
	const T* begin() const { return _po; }
	const T* end() const { return _po+_size; }
	const T* cbegin() const { return _po; }
	const T* cend() const { return _po+_size; }
	

	// known desired array size
	template<typename ...Args>
	array(size_t n, const std::string& file, Args...args)
	: alloc(n*sizeof(T), file)
	, _size{n}
	, _po{reinterpret_cast<T*>(alloc::map())}
	{
		for(size_t i=alloc::initialized()/sizeof(T); i < _size; ++i)
			new(_po+i) T(args...); 
	}

	// existing file
	array(const std::string& file)
	: alloc(file)
	, _size{alloc::size()/sizeof(T)}
	, _po{reinterpret_cast<T*>(alloc::map())}
	{}

};


}//persistent
#endif
