#include "../axis.h"

#include <limits>
#include <utility>


namespace MATH_NAMESPACE
{


//--------------------------------------------------------------------------------------------------
// aabb members
//

template < typename T >
inline basic_aabb< T >::basic_aabb()
{
}

template < typename T >
inline basic_aabb< T >::basic_aabb
(
    typename basic_aabb< T >::vec_type const& min,
    typename basic_aabb< T >::vec_type const& max
)
    : min(min)
    , max(max)
{
}

template < typename T >
template < typename U >
inline basic_aabb< T >::basic_aabb(vector< 3, U > const& min, vector< 3, U > const& max)
    : min(min)
    , max(max)
{
}

template < typename T >
inline typename basic_aabb< T >::vec_type basic_aabb< T >::center() const
{
    return (max + min) * value_type(0.5);
}

template < typename T >
inline typename basic_aabb< T >::vec_type basic_aabb< T >::size() const
{
    return max - min;
}

template <typename T>
inline vector<3, T> basic_aabb<T>::safe_size() const
{
    auto s = max - min;

    s.x = MATH_NAMESPACE::max(T(0.0), s.x);
    s.y = MATH_NAMESPACE::max(T(0.0), s.y);
    s.z = MATH_NAMESPACE::max(T(0.0), s.z);

    return s;
}

template <typename T>
inline void basic_aabb<T>::invalidate()
{
    min = vec_type(std::numeric_limits<T>::max());
    max = vec_type(std::numeric_limits<T>::lowest());
}

template <typename T>
inline bool basic_aabb<T>::invalid() const
{
    return min.x > max.x || min.y > max.y || min.z > max.z;
}

template <typename T>
inline bool basic_aabb<T>::valid() const
{
    return min.x <= max.x && min.y <= max.y && min.z <= max.z;
}

template <typename T>
inline bool basic_aabb<T>::empty() const
{
    return min.x >= max.x || min.y >= max.y || min.z >= max.z;
}

template < typename T >
inline bool basic_aabb< T >::contains(typename basic_aabb< T >::vec_type const& v) const
{
    return v.x >= min.x && v.x <= max.x
        && v.y >= min.y && v.y <= max.y
        && v.z >= min.z && v.z <= max.z;
}

template <typename T>
inline bool basic_aabb<T>::contains(basic_aabb<T> const& b) const
{
    return contains(b.min) && contains(b.max);
}


//--------------------------------------------------------------------------------------------------
// Geometric functions
//

template < typename T >
basic_aabb< T > combine(basic_aabb< T > const& a, basic_aabb< T > const& b)
{
    return basic_aabb< T >( min(a.min, b.min), max(a.max, b.max) );
}

template < typename T >
basic_aabb< T > intersect(basic_aabb< T > const& a, basic_aabb< T > const& b)
{
    return basic_aabb< T >( max(a.min, b.min), min(a.max, b.max) );
}

template <typename T>
T half_surface_area(basic_aabb<T> const& box)
{
    auto s = box.size();
    return s.x * s.y + s.y * s.z + s.z * s.x;
}

template <typename T>
T safe_half_surface_area(basic_aabb<T> const& box)
{
    auto s = box.safe_size();
    return s.x * s.y + s.y * s.z + s.z * s.x;
}

template <typename T>
T surface_area(basic_aabb<T> const& box)
{
    return 2 * half_surface_area(box);
}

template <typename T>
T safe_surface_area(basic_aabb<T> const& box)
{
    return 2 * safe_half_surface_area(box);
}

template <typename T>
T volume(basic_aabb<T> const& box)
{
    auto s = box.size();
    return s.x * s.y * s.z;
}

template < typename T >
std::pair< basic_aabb< T >, basic_aabb< T > > split(basic_aabb< T > const& box, cartesian_axis< 3 > axis, T splitpos)
{

    vector< 3, T > min1 = box.min;
    vector< 3, T > min2 = box.min;
    vector< 3, T > max1 = box.max;
    vector< 3, T > max2 = box.max;

    max1[axis] = splitpos;
    min2[axis] = splitpos;

    basic_aabb< T > box1(min1, max1);
    basic_aabb< T > box2(min2, max2);
    return std::make_pair(box1, box2);

}

template < typename T >
typename basic_aabb< T >::vertex_list compute_vertices(basic_aabb< T > const& box)
{

    vector< 3, T > min = box.min;
    vector< 3, T > max = box.max;

    typename basic_aabb< T >::vertex_list result =
    {{
        vector< 3, T >(max.x, max.y, max.z),
        vector< 3, T >(min.x, max.y, max.z),
        vector< 3, T >(min.x, min.y, max.z),
        vector< 3, T >(max.x, min.y, max.z),
        vector< 3, T >(min.x, max.y, min.z),
        vector< 3, T >(max.x, max.y, min.z),
        vector< 3, T >(max.x, min.y, min.z),
        vector< 3, T >(min.x, min.y, min.z)
    }};

    return result;

}

} // MATH_NAMESPACE


