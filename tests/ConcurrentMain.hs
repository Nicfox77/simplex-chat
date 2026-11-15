import ConcurrentTests (concurrentTests)
import Test.Hspec (hspec)

main :: IO ()
main = hspec concurrentTests
