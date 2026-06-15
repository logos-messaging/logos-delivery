
fn main() {
    println!("cargo:rustc-link-arg=-llogosdelivery");
    println!("cargo:rustc-link-arg=-L../../build/");
}
