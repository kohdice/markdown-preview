#[test]
fn test_vec_with_capacity() {
    let size = 100;
    let mut vec = Vec::with_capacity(size);

    for i in 0..size {
        vec.push(i);
    }

    assert!(vec.capacity() >= size);
    assert_eq!(vec.len(), size);
}

#[test]
fn test_iterator_collect_vs_push() {
    let result1: Vec<i32> = (0..100).filter(|x| x % 2 == 0).map(|x| x * 2).collect();

    let mut result2 = Vec::new();
    for i in 0..100 {
        if i % 2 == 0 {
            result2.push(i * 2);
        }
    }

    assert_eq!(result1, result2);
    assert_eq!(result1.len(), 50);
}

#[test]
fn test_extend_vs_multiple_push() {
    let data = vec![1, 2, 3, 4, 5];

    let mut vec1 = vec![0];
    vec1.extend(&data);

    let mut vec2 = vec![0];
    for &item in &data {
        vec2.push(item);
    }

    assert_eq!(vec1, vec2);
}

#[test]
fn test_filter_map_efficiency() {
    let input = ["1", "2", "invalid", "4", "5", "not_a_number"];

    let result1: Vec<i32> = input.iter().filter_map(|s| s.parse().ok()).collect();

    let result2: Vec<i32> = input
        .iter()
        .filter(|s| s.parse::<i32>().is_ok())
        .map(|s| s.parse().unwrap())
        .collect();

    assert_eq!(result1, result2);
    assert_eq!(result1, vec![1, 2, 4, 5]);
}

#[test]
fn test_chain_iterators() {
    let vec1 = [1, 2, 3];
    let vec2 = [4, 5, 6];

    let result: Vec<i32> = vec1.iter().chain(vec2.iter()).copied().collect();

    assert_eq!(result, vec![1, 2, 3, 4, 5, 6]);
}

#[test]
fn test_fold_vs_for_loop() {
    let numbers = vec![1, 2, 3, 4, 5];

    let sum1: i32 = numbers.iter().sum();

    let mut sum2 = 0;
    for &x in &numbers {
        sum2 += x;
    }

    let sum3: i32 = numbers.iter().sum();

    assert_eq!(sum1, sum2);
    assert_eq!(sum1, sum3);
    assert_eq!(sum1, 15);
}
