module mcl.utils.array;
import std.algorithm : all, uniq, sort;
import std.array : array;
import std.conv : to;
import std.traits : isArray, isSomeString;
import std.stdio : writeln;

T[] uniqIfSame(T)(T[] arr)
{
    if (arr.length == 0)
    {
        return arr;
    }
    else if (arr.all!(a => a == arr[0])) {
        return [arr[0]];
    }
    else {
        return arr;
    }

}

T uniqArrays(T)(T s){
    static if (isSomeString!T){
        return s;
    }
    else static if (isArray!T){
        return s.sort.uniq.array.to!T;
    }
    else static if (is(T == struct)){
        static foreach (idx, field; T.tupleof){
            s.tupleof[idx] = s.tupleof[idx].uniqArrays;
        }
        return s;
    }
    else{
        return s;
    }
}
