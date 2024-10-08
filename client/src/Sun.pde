class Animation {
  PImage[] images;
  int imageCount;
  int frame;
  float sun_radius = 175f;
  Animation(String model, int imageCount) {
    this.imageCount = imageCount;
    images = new PImage[imageCount];

    for (int i = 0; i < imageCount;i++){
      String filename = "sun/compressed/" + model + "_" + nf(i,5)+ ".png"; //!!!!!!!!!!!!!!!
      images[i] = loadImage(filename);
      images[i].resize(int(sun_radius*3),int(sun_radius*3));
    }
  }
  
  void display() {
    //frame_counter = (frame_counter+1) % imageCount;
    //if (frame_counter % 2 == 0) frame = (frame+1) % imageCount;
    pushMatrix();
    //translate(0,random(-1f,1f)); //!!!!!!!!!!!!!!!
    float x = displayWidth/2;
    float y = displayHeight/2;
    frame = (frame+1) % imageCount;
    noStroke();
    ellipse(x,y, sun_radius, sun_radius);
    image(images[frame], x-(sun_radius * 3 * 0.52), y-(sun_radius * 3 * 0.52)); // Offset due to .png dimensions. Purely aesthetic, won't be used in game logic.
    popMatrix();
  }
}
