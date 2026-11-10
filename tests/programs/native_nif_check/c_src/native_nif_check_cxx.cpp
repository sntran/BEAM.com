/*
 * The C++ part of native_nif_check.c: the object holds its own copy of
 * the parts of libc++ that it uses (build.sh links libcxx.a with ld -r),
 * and the program gives libc++abi (beam_com_nif_cxx.h). cxx_check gives
 * 0, or the number of the first check that failed.
 */
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

/* A static constructor: it runs at the load. */
struct Counter {
    int value;
    Counter() : value(41) {}
};
Counter counter;

struct Shape {
    virtual ~Shape() {}
    virtual int sides() const = 0;
};
struct Square : Shape {
    int sides() const override { return 4; }
};
struct Triangle : Shape {
    int sides() const override { return 3; }
};

struct MyError : std::runtime_error {
    int code;
    explicit MyError(int c) : std::runtime_error("my error"), code(c) {}
};

int thrower(int x)
{
    if (x > 2)
        throw MyError(x);
    if (x < 0)
        throw std::out_of_range("negative");
    return x * 2;
}

/* A function-local static (__cxa_guard_acquire). */
std::map<std::string, int> &table()
{
    static std::map<std::string, int> t = { { "one", 1 }, { "two", 2 } };
    return t;
}

int dtors;
struct PerThread {
    std::string name;
    PerThread() : name("per thread") {}
    ~PerThread() { __atomic_fetch_add(&dtors, 1, __ATOMIC_SEQ_CST); }
};
thread_local PerThread per_thread;

} // namespace

extern "C" int cxx_check(void)
{
    std::vector<std::string> words;
    std::string joined;
    Shape *shapes[2] = { new Square, new Triangle };
    int caught = 0;

    if (counter.value != 41)
        return 1;
    for (int i = 0; i < 100; i++)
        words.push_back("w" + std::to_string(i));
    for (const std::string &w : words)
        joined += w;
    if (words.size() != 100 || joined.size() != 290 || joined.substr(0, 4) != "w0w1")
        return 2;
    /* An exception of a derived type, caught by its base. */
    try {
        thrower(5);
    } catch (const std::exception &e) {
        const MyError *m = dynamic_cast<const MyError *>(&e);
        if (m && m->code == 5 && std::string(e.what()) == "my error")
            caught++;
    }
    /* An exception of libc++ (std::out_of_range), and a rethrow. */
    try {
        try {
            thrower(-1);
        } catch (...) {
            throw;
        }
    } catch (const std::logic_error &e) {
        if (std::string(e.what()) == "negative")
            caught++;
    }
    /* std::vector::at throws std::out_of_range. */
    try {
        (void)words.at(1000);
    } catch (const std::out_of_range &) {
        caught++;
    }
    if (caught != 3 || thrower(2) != 4)
        return 3;
    if (!dynamic_cast<Square *>(shapes[0]) || dynamic_cast<Square *>(shapes[1]) ||
        shapes[0]->sides() + shapes[1]->sides() != 7)
        return 4;
    delete shapes[0];
    delete shapes[1];
    table()["three"] = 3;
    if (table().size() != 3 || table()["two"] != 2)
        return 5;
    if (per_thread.name != "per thread")
        return 6;
    return 0;
}

/* The destructors of the thread_local objects of the threads that ended. */
extern "C" int cxx_dtors(void)
{
    return __atomic_load_n(&dtors, __ATOMIC_SEQ_CST);
}
